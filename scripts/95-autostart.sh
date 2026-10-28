#!/usr/bin/env bash
#
# Login autostart for the whole stack — `make autostart` / `make autostart-remove`.
#
# Installs a macOS launchd agent (~/Library/LaunchAgents) that fires at login
# and runs `make recover`: Docker Desktop comes up if it is not running, the
# kind containers are revived, the registry Endpoints and substrate worker
# registrations are re-synced (both break on every host/Docker restart), and
# all routes are probed. See scripts/05-recover.sh for the recovery itself.
#
#   install    write + bootstrap the agent, then test-run it
#   uninstall  bootout + remove the agent (leaves everything else alone)
#   status     show whether the agent is loaded and tail its last log lines
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LABEL="dev.kind-infra.recover"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG="$HOME/Library/Logs/kind-infra-recover.log"
# launchd gives agents a minimal PATH; bake in the tool locations that matter.
LAUNCH_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
GUI_ID="$(id -u)"

write_plist() {
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>export PATH="${LAUNCH_PATH}"; exec /usr/bin/make -C "${ROOT_DIR}" recover</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
EOF
}

is_loaded() { launchctl print "gui/${GUI_ID}/${LABEL}" >/dev/null 2>&1; }

cmd_install() {
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  write_plist
  is_loaded && launchctl bootout "gui/${GUI_ID}/${LABEL}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${GUI_ID}" "$PLIST"
  ok "agent ${LABEL} installed and loaded (runs 'make recover' at login)"
  say "Test-running the agent now (same code path as login)..."
  launchctl kickstart "gui/${GUI_ID}/${LABEL}"
  # The recover run may legitimately take minutes on a cold daemon; give it a
  # short window here and let the user tail the log for the rest.
  for _ in $(seq 1 12); do
    pgrep -f "make -C ${ROOT_DIR} recover" >/dev/null 2>&1 || break
    sleep 5
  done
  cmd_status
}

cmd_uninstall() {
  if is_loaded; then
    launchctl bootout "gui/${GUI_ID}/${LABEL}"
    ok "agent booted out"
  else
    warn "agent not loaded"
  fi
  [ -f "$PLIST" ] && rm "$PLIST" && ok "removed $PLIST"
  ok "autostart disabled (cluster unchanged; start manually with 'make recover')"
}

cmd_status() {
  if is_loaded; then
    ok "agent ${LABEL} is loaded — runs 'make recover' at login"
  else
    warn "agent ${LABEL} is NOT loaded — install with 'make autostart'"
  fi
  if [ -f "$LOG" ]; then
    say "last log lines ($LOG):"
    tail -5 "$LOG" | sed 's/^/    /'
  else
    warn "no log yet at $LOG"
  fi
}

case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  *) die "usage: bash scripts/95-autostart.sh {install|uninstall|status}" ;;
esac
