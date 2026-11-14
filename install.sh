#!/usr/bin/env bash
# Agent HQ installer for a Linux server (Ubuntu or Debian, ideally on 24/7). Safe to re-run.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Sidharth1914/agent-hq-kit/main/install.sh)
#
# What it does by itself: installs git, GitHub CLI, Python and Claude Code; makes your private job repo
# (github.com/<you>/agent-hq) from this kit; creates the job labels and a private phone-alert topic;
# installs the services (job worker every 5 min, live chat, watchdog, live page) and starts them.
# What needs you: signing in to GitHub and Claude, answering "y" once for the live chat, and (optional)
# signing in to Tailscale for the live page. Details: README.md.
set -euo pipefail
KIT=${HQ_KIT:-Sidharth1914/agent-hq-kit}
NAME=${HQ_REPO_NAME:-agent-hq}
HQ=$HOME/agent-hq
U=$(id -un)
say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ask() { local a; read -r -p "$1 [Y/n] " a </dev/tty; [[ ! $a =~ ^[Nn] ]]; }

[ "$(id -u)" -ne 0 ] || { echo "Run this as your normal user (it uses sudo when it needs to), not as root."; exit 1; }
command -v apt-get >/dev/null || { echo "This installer needs Ubuntu or Debian. On Windows, use install.ps1."; exit 1; }

say "1/8 Packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl jq python3 qrencode >/dev/null
if ! command -v gh >/dev/null; then
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq gh >/dev/null
fi

say "2/8 Claude Code"
export PATH=$HOME/.local/bin:$PATH
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
grep -qs 'HOME/.local/bin' "$HOME/.bashrc" || echo 'export PATH=$HOME/.local/bin:$PATH' >> "$HOME/.bashrc"

say "3/8 GitHub sign-in"
if ! gh auth status >/dev/null 2>&1; then
  echo "A code appears below. Open the link on any device (your phone works), sign in to GitHub and enter the code."
  gh auth login -h github.com -p https -w -s repo,workflow </dev/tty
fi
gh auth setup-git
ME=$(gh api user -q .login)
git config --global user.name >/dev/null || git config --global user.name "$ME"
git config --global user.email >/dev/null || git config --global user.email "$(gh api user -q .id)+$ME@users.noreply.github.com"

say "4/8 Your private job repo: github.com/$ME/$NAME"
if [ ! -f "$HQ/runner.py" ]; then
  if ! gh repo view "$ME/$NAME" >/dev/null 2>&1; then
    gh repo create "$ME/$NAME" --private --template "$KIT" >/dev/null
    echo "Created it from the Agent HQ kit (private: only you can see it)."
  fi
  for _ in 1 2 3 4 5 6 7 8; do   # a repo made from a template takes a few seconds to fill
    rm -rf "$HQ"; gh repo clone "$ME/$NAME" "$HQ" -- -q 2>/dev/null || true
    [ -f "$HQ/runner.py" ] && break; sleep 5
  done
fi
[ -f "$HQ/runner.py" ] || { echo "Could not clone $ME/$NAME. Check that it exists on GitHub, then re-run."; exit 1; }
git -C "$HQ" pull -q --ff-only || true
chmod +x "$HQ/deploy/hq-push" "$HQ/deploy/hq-watch.sh"
python3 "$HQ/runner.py" --selftest

say "5/8 Job labels and your phone-alert topic"
for l in working:FBCA04 needs-local:1D76DB needs-windows:5319E7 done:0E8A16 failed:D93F0B; do
  gh label create "${l%%:*}" -R "$ME/$NAME" --color "${l##*:}" --force >/dev/null
done
TOPIC=$(gh variable get NTFY_TOPIC -R "$ME/$NAME" 2>/dev/null || true)
if [ -z "$TOPIC" ]; then   # random, so nobody can guess it; kept as a variable in your private repo for your other machines
  TOPIC="hq-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  gh variable set NTFY_TOPIC -R "$ME/$NAME" --body "$TOPIC"
fi
umask 077
[ -f "$HQ/.env" ] || printf 'NTFY_TOPIC=%s\nHQ_DIRS=%s\n' "$TOPIC" "$HOME/Downloads" > "$HQ/.env"
chmod 600 "$HQ/.env"
umask 022
mkdir -p "$HOME/work" "$HOME/Downloads" "$HOME/results/chat" "$HOME/.local/bin"
ln -sf "$HQ/deploy/hq-push" "$HOME/.local/bin/hq-push"

say "6/8 Claude sign-in and live chat"
if [ ! -s "$HOME/.claude/.credentials.json" ]; then
  echo "Claude opens now. Type /login, sign in with your Claude account (Pro or Max), then type /exit."
  (cd "$HQ" && claude </dev/tty) || true
fi
if [ ! -f "$HQ/.rc-ok" ]; then
  echo "The live chat now starts once by hand. Answer y to \"Enable Remote Control?\" and y to trusting the folder."
  echo "When it shows the session link, press Ctrl+C and the install carries on."
  trap 'true' INT
  (cd "$HQ" && claude remote-control --name "Agent HQ" </dev/tty) || true
  trap - INT
  touch "$HQ/.rc-ok"
fi

say "7/8 Services"
P="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin"
sudo tee /etc/systemd/system/agent-hq-worker.service >/dev/null <<EOF
[Unit]
Description=Agent HQ worker (one pass over needs-local issues)
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
User=$U
WorkingDirectory=$HQ
Environment=PATH=$P
ExecStart=/usr/bin/python3 $HQ/runner.py --label needs-local --where server
TimeoutStartSec=4h
EOF
sudo tee /etc/systemd/system/agent-hq-worker.timer >/dev/null <<EOF
[Unit]
Description=Run the Agent HQ worker 5 minutes after the last pass
[Timer]
OnBootSec=2min
OnUnitInactiveSec=5min
[Install]
WantedBy=timers.target
EOF
sudo tee /etc/systemd/system/agent-hq-remote.service >/dev/null <<EOF
[Unit]
Description=Agent HQ live chat (Claude Remote Control)
Wants=network-online.target
After=network-online.target
[Service]
User=$U
WorkingDirectory=$HQ
Environment=PATH=$P
EnvironmentFile=$HQ/.env
ExecStart=/usr/bin/script -qfc "claude remote-control --name 'Agent HQ' --spawn worktree --capacity 3 --permission-mode auto" /dev/null
Restart=always
RestartSec=30
[Install]
WantedBy=multi-user.target
EOF
# The watchdog runs as root, so it runs from a root-owned copy that agents cannot edit. Re-run this script to update it.
sudo install -o root -g root -m 755 "$HQ/deploy/hq-watch.sh" /usr/local/sbin/hq-watch
sudo tee /etc/systemd/system/hq-watch.service >/dev/null <<EOF
[Unit]
Description=Agent HQ watchdog: restart dead services, push the phone about failures
[Service]
Type=oneshot
Environment=HQ_USER=$U
ExecStart=/usr/local/sbin/hq-watch
EOF
sudo tee /etc/systemd/system/hq-watch.timer >/dev/null <<EOF
[Unit]
Description=Run the Agent HQ watchdog every 10 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOF
sudo tee /etc/systemd/system/hq-status.service >/dev/null <<EOF
[Unit]
Description=Agent HQ live page (private Unix socket; tailscale serve shows it to you only)
After=network-online.target
[Service]
User=$U
Environment=PATH=$P
EnvironmentFile=$HQ/.env
RuntimeDirectory=hq-status
RuntimeDirectoryMode=0700
ExecStart=/usr/bin/python3 $HQ/deploy/hq_status.py --serve /run/hq-status/hq.sock
Restart=always
RestartSec=10
MemoryMax=80M
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now agent-hq-worker.timer agent-hq-remote.service hq-watch.timer hq-status.service

say "8/8 Phone"
URL=""
if ask "Set up the live animated page for your phone? It needs a free Tailscale account and the Tailscale app."; then
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale status >/dev/null 2>&1 || { echo "Open the link below and sign in to Tailscale (use the same account on your phone)."; sudo tailscale up; }
  if sudo tailscale serve --bg --https=9443 unix:/run/hq-status/hq.sock; then
    sudo systemctl restart hq-status   # it learns who you are from Tailscale when it starts
    URL="https://$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//'):9443"
  else
    echo "Tailscale asks you to turn on HTTPS for your network (link above). Do that, then re-run this installer."
  fi
fi
echo
echo "Install the ntfy app on your phone, tap +, and subscribe to this topic (or scan the code):"
echo "    $TOPIC"
qrencode -t ansiutf8 "https://ntfy.sh/$TOPIC" 2>/dev/null || true
"$HOME/.local/bin/hq-push" "✅ Agent HQ is installed on $(hostname)" >/dev/null || true

cat <<EOF

Agent HQ is running.
  Live chat:   Claude app > Code > "Agent HQ" (talk to your agents there)
  Jobs:        open an issue in https://github.com/$ME/$NAME/issues (it starts within 5 minutes)
  Phone alerts: ntfy topic $TOPIC (a test push was just sent)
${URL:+  Live page:   $URL (Tailscale on)}
  Make it yours: edit the "Your projects" table in $HQ/CLAUDE.md and push it.
EOF
