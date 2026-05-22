#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Library/Application Support/CapsDocsCapture"
BIN="$APP_DIR/CapsDocsCapture"
LOG_DIR="$HOME/.caps-docs-capture"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
DAEMON_PLIST="$LAUNCH_DIR/com.alessandro.CapsDocsCapture.plist"
UID_VALUE="$(id -u)"

cd "$ROOT_DIR"
swift build -c release

mkdir -p "$APP_DIR" "$LOG_DIR" "$LAUNCH_DIR"
install -m 755 ".build/release/CapsDocsCapture" "$BIN"

pkill -f '/CapsDocsCapture --daemon' >/dev/null 2>&1 || true
rm -rf "$HOME/Applications/CapsDocsCapture.app"
launchctl bootout "gui/$UID_VALUE" "$DAEMON_PLIST" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_VALUE" "$LAUNCH_DIR/com.alessandro.CapsLockToF18.plist" >/dev/null 2>&1 || true

rm -f "$DAEMON_PLIST" "$LAUNCH_DIR/com.alessandro.CapsLockToF18.plist"
"$BIN" --unmap-capslock >/dev/null 2>&1 || true

cat <<EOF
Installed CapsDocsCapture.

Next:
1. Add this binary to Accessibility if macOS prompts:
   $BIN
2. Connect Google Docs (one time). See DESIGN.md for the Cloud setup:
   "$BIN" --google-auth /path/to/client_secret_*.json
3. Make sure Karabiner-Elements has this complex modification enabled in:
   ~/.config/karabiner/karabiner.json
4. Start the daemon:
   "$BIN" --daemon
5. Click in your notes Doc and press Shift-Caps Lock to set the target.

Keep the daemon process running while you capture notes. Stop it with Ctrl-C or:
   "$BIN" --stop

EOF
