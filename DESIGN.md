# CapsDocsCapture — Design

## The idea

A macOS helper that pipes highlighted text from anywhere into one Google Doc,
driven by two hotkeys:

- **Shift + Caps Lock** — while your cursor is in a Google Doc, mark that Doc as
  the capture target and remember the cursor spot.
- **Caps Lock** — highlight text in any other app or window, tap Caps Lock, and
  the text is written into the target Doc automatically. You do not leave the
  window you are in.

## Why this rewrite

The previous version pasted into the Doc by switching browser tabs/windows with
AppleScript and simulated clicks. ChatGPT Atlas is not fully AppleScript-
scriptable, so target focusing failed — the logs show `open URL timed out`,
`target front visual mismatch: screen=(none)`, and `no docs target available`.
The text was copied fine; the "focus the Doc and paste" step was the house of
cards, and Atlas knocked it down.

New approach: write to the Doc through the **Google Docs API**, addressed by
document ID. No tab switching, no focus stealing, no simulated clicks. The
capture lands in the Doc whether or not it is visible, and you stay in the
source window.

## Workflow

1. Start the daemon: `CapsDocsCapture --daemon`. It enables the hotkeys for one
   hour.
2. One-time: connect Google Docs with `--google-auth` (see setup below).
3. Click in your notes Doc where captures should start, then press
   **Shift + Caps Lock**. This saves the Doc as the target and drops an
   invisible anchor at the cursor.
4. Switch to any app or window. Highlight text.
5. Press **Caps Lock**. The text is inserted into the target Doc at the anchor,
   followed by a newline. The anchor moves down, so the next capture continues
   right after.

You can type your own notes in the Doc between captures — the anchor is real
(invisible) document text, so it rides along with your edits and the next
capture still lands at the anchor.

## Architecture

- **Hotkeys** — Karabiner-Elements maps `Shift+Caps Lock` to run
  `CapsDocsCapture --set-target` and `Caps Lock` to run `CapsDocsCapture --once`.
  Both run as short-lived processes. The `--daemon` process only flips a
  Karabiner variable (`caps_docs_capture_enabled`) on/off and auto-quits after
  one hour, so the hotkeys are not live when you are not using them.

- **`--set-target`** — reads the front browser tab's URL (works for Atlas and
  Chromium browsers), extracts the Google document ID, pastes an invisible
  anchor (a run of six `U+200B` zero-width spaces) at the cursor, and confirms
  the anchor exists by reading the Doc back through the API. If the anchor can't
  be confirmed it falls back to append-to-end mode.

- **`--once`** — reads the currently selected text (Accessibility API, with a
  `Cmd+C` clipboard fallback), then calls `documents.batchUpdate` to insert the
  text just before the anchor. With no anchor, it appends to the end of the Doc.
  Focus never changes; the clipboard is saved and restored.

- **The anchor** — because it is ordinary (invisible) text in the document, the
  Docs API reports its current index every time we read the Doc. Manual edits
  before the anchor shift it; the capture logic always re-finds it. No fragile
  index bookkeeping is kept on disk.

- **Auth** — OAuth 2.0 for an installed app: PKCE plus a loopback redirect
  (`http://127.0.0.1:<port>`). Scope is `https://www.googleapis.com/auth/documents`.
  Tokens are stored in `~/.caps-docs-capture/google-tokens.json` and refreshed
  automatically when the access token expires.

## One-time Google setup

1. Open <https://console.cloud.google.com/> and create a project.
2. In **APIs & Services > Library**, enable the **Google Docs API**.
3. In **APIs & Services > OAuth consent screen**, create one (User type
   *External*), add your own Google account as a test user. To avoid re-auth
   every 7 days, set the publishing status to **In production** (an unverified
   app still works for your own account; you just click past a warning once).
4. In **APIs & Services > Credentials**, create an **OAuth client ID** of type
   **Desktop app**. Download the `client_secret_*.json` file.
5. Run: `CapsDocsCapture --google-auth /path/to/client_secret_*.json`. A browser
   window opens; approve access. Tokens are saved locally.

## Known limitations

- The Docs API cannot see your live editor caret. The anchor is our own
  bookmark, placed where the cursor was at `--set-target` time. Captures land at
  the anchor, not necessarily at wherever you most recently clicked.
- `--set-target` needs the Doc to be the front browser tab so the anchor can be
  pasted and the URL read. `--set-target-url <id>` saves a Doc by ID without an
  anchor (append-to-end mode).
- OAuth refresh tokens for an app left in *Testing* mode expire after 7 days.
  Set the consent screen to *In production* to avoid weekly re-auth.

## Files

- Binary: `~/Library/Application Support/CapsDocsCapture/CapsDocsCapture`
- Target, tokens, logs: `~/.caps-docs-capture/`
- Karabiner rule: `~/.config/karabiner/karabiner.json`
