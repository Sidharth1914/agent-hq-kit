#!/usr/bin/env bash
# VM watchdog (root, every 10 min). Fixes what it can and pushes the phone about the rest:
#  1. a core service that is down gets restarted; if it stays down, a high push
#  2. any failed unit (agent-hq-*, hq-*, trader-*, ...) is reported once, then cleared so the next failure reports again
#  3. disk over 90% gets a push
# Each problem pushes at most once every 6 hours (stamp files), so a long outage is not a flood.
set -uo pipefail
U=${HQ_USER:?set HQ_USER to the Agent HQ login user}
UHOME=$(getent passwd "$U" | cut -d: -f6)
STAMPS=/var/lib/hq-watch
mkdir -p "$STAMPS"

push() {  # push KEY TEXT
  local s="$STAMPS/$1"
  if [ -f "$s" ] && [ $(( $(date +%s) - $(stat -c %Y "$s") )) -lt 21600 ]; then return; fi
  runuser -u "$U" -- "$UHOME/.local/bin/hq-push" "$2" high && touch "$s"
}

for u in agent-hq-remote.service tailscaled.service agent-hq-worker.timer hq-status.service; do
  systemctl is-enabled -q "$u" 2>/dev/null || continue
  if ! systemctl is-active -q "$u"; then
    systemctl reset-failed "$u" 2>/dev/null
    systemctl restart "$u"
    sleep 20
    systemctl is-active -q "$u" || push "down-$u" "❌ VM: $u is down and a restart did not fix it. ssh in: journalctl -u $u -n 50"
  fi
done

for u in $(systemctl list-units --state=failed --plain --no-legend | awk '{print $1}'); do
  # Unit name only: log lines can hold secrets and the ntfy topic is a public URL.
  push "failed-$u" "❌ VM: $u failed. ssh in: journalctl -u $u -n 50"
  systemctl reset-failed "$u"
done

use=$(df --output=pcent / | tail -1 | tr -dc 0-9)
[ "$use" -lt 90 ] || push disk "⚠ VM disk is ${use}% full. Clean ~/work or journal logs."
exit 0
