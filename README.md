# CapsDocsCapture

macOS helper that sends highlighted text from any app into one Google Doc,
using two hotkeys. See [DESIGN.md](DESIGN.md) for the idea and architecture.

## Workflow

1. Start the daemon (enables the hotkeys for 1 hour).
2. Click in your notes Doc where captures should start, then press
   **Shift-Caps Lock** to save it as the target.
3. Switch to any other app or window and highlight some text.
4. Press **Caps Lock**. The text is written into the target Doc via the Google
   Docs API. Focus does not change — you stay where you are.

Captures land at an invisible anchor placed where your cursor was. The anchor is
real document text, so you can type your own notes between captures and the next
capture still continues from the anchor.

## Install

```sh
./install.sh
```

Installed files:

- Binary: `~/Library/Application Support/CapsDocsCapture/CapsDocsCapture`
- Target, tokens, logs: `~/.caps-docs-capture/`
- Karabiner rule: `~/.config/karabiner/karabiner.json`

The helper needs macOS **Accessibility** permission to read selected text and
send keystrokes. Add the binary in:

```text
System Settings > Privacy & Security > Accessibility
~/Library/Application Support/CapsDocsCapture/CapsDocsCapture
```

## Connect Google Docs (one time)

1. Create a project at <https://console.cloud.google.com/>.
2. Enable the **Google Docs API** (APIs & Services > Library).
3. Configure the **OAuth consent screen** (User type *External*; add your own
   account as a test user). Set publishing status to *In production* to avoid
   re-authorizing every 7 days.
4. Create an **OAuth client ID** of type **Desktop app** (APIs & Services >
   Credentials) and download its `client_secret_*.json`.
5. Run:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --google-auth /path/to/client_secret_*.json
```

A browser window opens; approve access. Tokens are stored and auto-refreshed.

## Daily commands

Start the daemon:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --daemon
```

Keep that process running while you capture notes. It auto-quits after 1 hour.
Stop it manually:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --stop
```

Show configuration:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --status
```

Watch the log:

```sh
tail -f ~/.caps-docs-capture/capture.log
```

## Target commands

Save the focused Google Doc as the target (same as Shift-Caps Lock). The Doc
must be the front browser tab with your cursor in the body:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --set-target
```

Save a Doc by URL or document ID (no cursor anchor; captures append to the end):

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --set-target-url 'DOC_ID_OR_URL'
```

Quote full URLs.

## Testing

Build:

```sh
swift build -c release
```

Capture once without a hotkey:

```sh
~/Library/Application\ Support/CapsDocsCapture/CapsDocsCapture --once
```

## How it works

Karabiner-Elements maps the hotkeys to short-lived helper processes while the
daemon is running:

- **Caps Lock** runs `--once`: read the selected text, then insert it into the
  target Doc through the Google Docs API.
- **Shift-Caps Lock** runs `--set-target`: read the front browser tab's URL,
  drop an invisible anchor at the cursor, and save the Doc.

The tool writes through the Docs API instead of switching browser tabs and
pasting. This works even when the Doc is in ChatGPT Atlas (which is not fully
AppleScript-scriptable) or in a different window, and it never steals focus.
