# CapsDocsCapture

Local macOS helper for this workflow:

1. Put the cursor in the Google Doc where notes should be inserted.
2. Press Shift-Caps Lock to save that Google Doc as the target.
3. Highlight text in another window.
4. Press Caps Lock.
5. The selected text is copied, pasted into the saved Google Docs window, and focus returns to the source app when possible.

## Installed Files

- Binary: `~/Library/Application Support/CapsDocsCapture/CapsDocsCapture`
- Config and logs: `~/.caps-docs-capture/`

## Commands

Build:

```sh
swift build -c release
```

Save the currently focused Google Doc as the target:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --set-target
```

When the daemon is running, you can also click the Google Doc and press
Shift-Caps Lock to save it as the target.

Save a specific open Google Doc by URL/document id:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --set-target-url DOC_ID_OR_URL_FRAGMENT
```

List open Google Docs:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --list-docs
```

Install the helper:

```sh
./install.sh
```

Start the interactive daemon:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --daemon
```

Starting the daemon enables the Karabiner-Elements Caps Lock rule by setting
`caps_docs_capture_enabled=1`. Stopping it disables that rule so Caps Lock goes
back to normal.

The daemon automatically quits after 1 hour and restores Caps Lock.

Stop it:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --stop
```

Trigger the running daemon once for testing:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --trigger-daemon
```

The primary Caps Lock hotkey is a Karabiner-Elements complex modification at:

```text
~/.config/karabiner/karabiner.json
```

It runs the installed helper with `--once` when Caps Lock is tapped alone, and
with `--set-target` when Shift-Caps Lock is pressed. Both shortcuts require
`caps_docs_capture_enabled` to be set. `--stop` also clears any previous Caps
Lock remapping left from older versions.

## Permissions

The helper needs macOS Accessibility permission to send copy/paste keystrokes, and Input Monitoring permission to receive raw Caps Lock key events. Add this binary to both entries in:

```text
System Settings > Privacy & Security > Accessibility
System Settings > Privacy & Security > Input Monitoring
~/Library/Application Support/CapsDocsCapture/CapsDocsCapture
```

Then restart the daemon.

## Notes

This intentionally uses the live Google Docs cursor instead of the Google Docs API. The target Docs window should be visible or focusable, and the cursor should already be placed where the next capture should land.

The helper is intentionally run as an interactive daemon instead of a LaunchAgent. On current macOS, the LaunchAgent process can start but does not receive the same Accessibility/Input Monitoring privileges needed to copy the selected text from the foreground app.
