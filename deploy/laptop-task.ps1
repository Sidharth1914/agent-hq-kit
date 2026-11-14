# Registers the Windows task AgentHQWindows: every 10 minutes, runner.py does one pass over
# open agent-hq issues labelled needs-windows (Windows-only jobs). With no such issue it exits at once.
# conhost --headless: Windows Terminal as the default host kills hidden consoles.
$root = Split-Path $PSScriptRoot
$py = (Get-Command py).Source
$arg = "--headless `"$py`" -3 `"$root\runner.py`" --label needs-windows --where laptop"
$action = New-ScheduledTaskAction -Execute "conhost.exe" -Argument $arg -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName AgentHQWindows -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Get-ScheduledTask AgentHQWindows | Select-Object TaskName, State
