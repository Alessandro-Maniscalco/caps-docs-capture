#!/bin/zsh
set -euo pipefail

UID_VALUE="$(id -u)"
DAEMON_PLIST="$HOME/Library/LaunchAgents/com.alessandro.CapsDocsCapture.plist"
MAP_PLIST="$HOME/Library/LaunchAgents/com.alessandro.CapsLockToF18.plist"
BIN="$HOME/Library/Application Support/CapsDocsCapture/CapsDocsCapture"
APP_BUNDLE="$HOME/Applications/CapsDocsCapture.app"

pkill -f '/CapsDocsCapture --daemon' >/dev/null 2>&1 || true
pkill -f '/usr/bin/open -W -g .*/CapsDocsCapture[.]app' >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE" "$DAEMON_PLIST" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE" "$MAP_PLIST" >/dev/null 2>&1 || true

if [ -x "$BIN" ]; then
  "$BIN" --unmap-capslock >/dev/null 2>&1 || true
fi

rm -f "$DAEMON_PLIST" "$MAP_PLIST"
rm -rf "$APP_BUNDLE"

cat <<EOF
Stopped CapsDocsCapture and removed LaunchAgents/app wrapper.

The binary and logs were left in place:
  $HOME/Library/Application Support/CapsDocsCapture
  $HOME/.caps-docs-capture

EOF
