# CapsDocsCapture

macOS helper for sending highlighted text into the current cursor position in
Google Docs.

## Workflow

1. Start the daemon.
2. Click in the Google Doc body where notes should be inserted.
3. Press Shift-Caps Lock to save that Docs window and body click point as the target.
4. Highlight text in another app or browser window.
5. Press Caps Lock to paste the selected text into the saved Docs target.

After each capture, focus returns to the source app when possible.

## Install

```sh
./install.sh
```

Installed files:

- Binary: `~/Library/Application Support/CapsDocsCapture/CapsDocsCapture`
- Config and logs: `~/.caps-docs-capture/`
- Karabiner rule: `~/.config/karabiner/karabiner.json`

The helper needs macOS Accessibility permission to send copy/paste keystrokes,
and Input Monitoring permission to receive raw Caps Lock key events. Add this
binary to both entries:

```text
System Settings > Privacy & Security > Accessibility
System Settings > Privacy & Security > Input Monitoring
~/Library/Application Support/CapsDocsCapture/CapsDocsCapture
```

Restart the daemon after changing permissions.

## Daily Commands

Start the daemon:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --daemon
```

The daemon enables the Karabiner-Elements Caps Lock rule while it is running,
then restores Caps Lock when it stops. It automatically quits after 1 hour.

Stop it manually:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --stop
```

Watch app logs:

```sh
tail -f ~/.caps-docs-capture/capture.log
```

Watch Karabiner shortcut events:

```sh
tail -f ~/.caps-docs-capture/karabiner.log
```

Show current configuration:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --status
```

## Target Commands

Save the currently focused Google Doc as the target:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --set-target
```

When the daemon is running, Shift-Caps Lock does the same thing. The mouse
must be inside the document body, not on the toolbar or browser tabs, so the
helper can safely refocus the editor before pasting.

Save a specific open Google Doc by URL or document ID:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --set-target-url 'DOC_ID_OR_URL_FRAGMENT'
```

Quote full URLs. In zsh, an unquoted `?tab=t.0` is treated as a filename
pattern before CapsDocsCapture can read it. Passing only the document ID avoids
that issue. This command saves the document target only; use Shift-Caps Lock
after clicking in the document body when `--status` shows `Target body click
point: not saved`.

List open Google Docs:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --list-docs
```

## Testing

Build:

```sh
swift build -c release
```

Trigger the running daemon once:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --trigger-daemon
```

Capture once without the daemon:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --once
```

## How It Works

The Karabiner-Elements complex modification maps Caps Lock while the daemon is
running:

- Caps Lock: capture selected text and paste it into the saved Docs target.
- Shift-Caps Lock: save the focused Google Docs window as the target.

The helper intentionally uses the live Google Docs cursor instead of the Google
Docs API. The target Docs window should be visible or focusable. For reliable
pasting, save a target body click point with Shift-Caps Lock after placing the
cursor where the next capture should land.

The daemon runs interactively instead of as a LaunchAgent. On current macOS, a
LaunchAgent process can start but may not receive the same
Accessibility/Input Monitoring privileges needed to copy selected text from the
foreground app.
