# Agent HQ installer for Windows 10/11. Safe to re-run. Run in PowerShell (no admin needed):
#
#   irm https://raw.githubusercontent.com/Sidharth1914/agent-hq-kit/main/install.ps1 | iex
#
# What it does by itself: installs Git, GitHub CLI, Python and Claude Code (winget); makes or reuses your
# private job repo github.com/<you>/agent-hq; creates the job labels and phone-alert topic; registers the
# task that runs Windows jobs every 10 minutes. If this PC is your only machine, it also runs the live chat
# and sends every new job here. What needs you: signing in to GitHub and Claude, and answering "y" once.
$ErrorActionPreference = 'Continue'
$Kit  = if ($env:HQ_KIT) { $env:HQ_KIT } else { 'Sidharth1914/agent-hq-kit' }
$Name = if ($env:HQ_REPO_NAME) { $env:HQ_REPO_NAME } else { 'agent-hq' }
$HQ   = Join-Path $HOME 'agent-hq'

function Say($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Fail($t) { Write-Host $t -ForegroundColor Red; throw $t }
function RefreshPath { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ";$HOME\.local\bin" }
function Need($cmd, $id) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    Write-Host "Installing $id ..."
    winget install -e --id $id --accept-source-agreements --accept-package-agreements --silent | Out-Null
    RefreshPath
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Fail "$id did not install. Install it by hand, then re-run." }
  }
}

Say '1/6 Tools: Git, GitHub CLI, Python, Claude Code'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Fail 'winget is missing. Install "App Installer" from the Microsoft Store, then re-run.' }
Need git Git.Git
Need gh GitHub.cli
Need py Python.Python.3.12
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression; RefreshPath }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Fail 'Claude Code did not install. See https://claude.com/claude-code, then re-run.' }

Say '2/6 GitHub sign-in'
gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host 'A code appears below. Open the link, sign in to GitHub and enter the code.'
  gh auth login -h github.com -p https -w -s repo,workflow
}
gh auth setup-git
$Me = gh api user -q .login
if (-not $Me) { Fail 'GitHub sign-in did not finish. Re-run the installer.' }
if (-not (git config --global user.name)) { git config --global user.name $Me }
if (-not (git config --global user.email)) { git config --global user.email "$(gh api user -q .id)+$Me@users.noreply.github.com" }

Say "3/6 Your private job repo: github.com/$Me/$Name"
if (-not (Test-Path "$HQ\runner.py")) {
  gh repo view "$Me/$Name" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    gh repo create "$Me/$Name" --private --template $Kit | Out-Null
    Write-Host 'Created it from the Agent HQ kit (private: only you can see it).'
  }
  foreach ($i in 1..8) {   # a repo made from a template takes a few seconds to fill
    if (Test-Path $HQ) { Remove-Item -Recurse -Force $HQ }
    gh repo clone "$Me/$Name" $HQ -- -q 2>$null
    if (Test-Path "$HQ\runner.py") { break }
    Start-Sleep 5
  }
}
if (-not (Test-Path "$HQ\runner.py")) { Fail "Could not clone $Me/$Name. Check it exists on GitHub, then re-run." }
git -C $HQ pull -q --ff-only 2>$null
py -3 "$HQ\runner.py" --selftest

Say '4/6 Job labels and your phone-alert topic'
foreach ($l in 'working:FBCA04', 'needs-local:1D76DB', 'needs-windows:5319E7', 'done:0E8A16', 'failed:D93F0B') {
  $n, $c = $l.Split(':'); gh label create $n -R "$Me/$Name" --color $c --force | Out-Null
}
$Topic = gh variable get NTFY_TOPIC -R "$Me/$Name" 2>$null
if (-not $Topic) {   # random, so nobody can guess it; kept as a variable in your private repo for your other machines
  $Topic = 'hq-' + -join ((1..24) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
  gh variable set NTFY_TOPIC -R "$Me/$Name" --body $Topic
}
if (-not (Test-Path "$HQ\.env")) {
  Set-Content -Path "$HQ\.env" -Encoding ascii -Value "NTFY_TOPIC=$Topic`r`nHQ_DIRS=$HOME\Downloads"
}

Say '5/6 Claude sign-in and the Windows job task'
if (-not (Test-Path "$HOME\.claude\.credentials.json")) {
  Write-Host 'Claude opens now. Type /login, sign in with your Claude account (Pro or Max), then type /exit.'
  Push-Location $HQ; claude; Pop-Location
}
& "$HQ\deploy\laptop-task.ps1"

$only = Read-Host 'Is this PC your only Agent HQ machine (no Linux server)? [y/N]'
if ($only -match '^[yY]') {
  # New issues get needs-windows, so this PC runs them; and the live chat runs here while the PC is on.
  gh variable set HQ_DEFAULT_LABEL -R "$Me/$Name" --body needs-windows
  $cmd = "$HQ\start-live-chat.cmd"
  Set-Content -Path $cmd -Encoding ascii -Value "@echo off`r`ntitle Agent HQ live chat (keep this window open)`r`ncd /d `"$HQ`"`r`nclaude remote-control --name `"Agent HQ`" --spawn worktree --capacity 3 --permission-mode auto"
  $startup = [Environment]::GetFolderPath('Startup')
  Set-Content -Path "$startup\Agent HQ live chat.cmd" -Encoding ascii -Value "@echo off`r`nstart `"Agent HQ`" /min cmd /c `"$cmd`""
  Start-Process cmd -ArgumentList '/c', "`"$cmd`""
  Write-Host 'A window "Agent HQ live chat" opened. Answer y to "Enable Remote Control?" and to trusting the folder, then minimise it.'
  Write-Host 'It starts by itself, minimised, every time you sign in to Windows.'
}

Say '6/6 Phone'
Write-Host 'Install the ntfy app on your phone, tap +, and subscribe to this topic:'
Write-Host "    $Topic" -ForegroundColor Yellow
Write-Host "    (or open https://ntfy.sh/$Topic on the phone)"
try { Invoke-RestMethod -Method Post -Uri "https://ntfy.sh/$Topic" -Body "Agent HQ is installed on $env:COMPUTERNAME" -Headers @{ Title = 'Agent HQ' } | Out-Null } catch {}

Write-Host @"

Agent HQ is set up on this PC.
  Jobs:         open an issue in https://github.com/$Me/$Name/issues
                (label needs-windows runs it here within 10 minutes, while the PC is on)
  Live chat:    Claude app > Code > "Agent HQ" (on the Linux server, or here if this PC is your only machine)
  Phone alerts: ntfy topic $Topic (a test push was just sent)
  Make it yours: edit the "Your projects" table in $HQ\CLAUDE.md and push it.
"@
