# focus

A focus-mode orchestrator for macOS that kills distractions **and** stands guard over your
notifications — so you can close everything and trust that only genuinely urgent things
will break through.

When you start a session, `focus`:

1. **Quits messaging apps** (Slack, Telegram, WhatsApp, Mail) — reopened when you're done.
2. **Cleans your workspace with AI** — looks at every open window, asks an LLM which apps
   are unrelated to the task you declared, and offers to close them.
3. **Hides the Dock and menu bar**, enables Do Not Disturb, and dims everything but the
   active window (via [HazeOver](https://hazeover.com)).
4. **Runs a sentinel** — while you focus, it watches incoming Slack/WhatsApp/Telegram
   notifications, holds everything back, and interrupts you *only* for what your rules
   consider critical. Everything else lands in an end-of-session digest.

The "is this urgent?" judgment is made by **Claude**, called through the
[Claude Code](https://claude.com/claude-code) CLI you already have installed — no extra
API key, no extra provider.

## Why

Most focus tools either block everything (and you miss the one message that mattered) or
block nothing (and you never disconnect). The hard part isn't blocking — it's triage. No
off-the-shelf product reads your Slack + WhatsApp + Telegram and decides, with context,
what deserves to interrupt you. This does, locally.

## Install

Requires macOS 13+, Swift 6, and the `claude` CLI on your PATH.

```bash
git clone https://github.com/<you>/focus.git
cd focus
swift build -c release
ln -sf "$PWD/.build/release/focus" ~/bin/focus   # make sure ~/bin is on your PATH
```

Copy the config and edit it with your own rules (names, channels, family group):

```bash
cp .focusrc.example ~/.focusrc
$EDITOR ~/.focusrc
```

### Optional: HazeOver (window dimming)

The "dim everything but the active window" step is powered by
[HazeOver](https://hazeover.com) ($4.99, one-time on the Mac App Store), driven through its
AppleScript interface:

```applescript
tell application "HazeOver" to set enabled to true   -- on session start
tell application "HazeOver" to set enabled to false  -- on session end
```

It's entirely optional — if HazeOver isn't installed, that step is simply skipped and the
rest of `focus` works unchanged. HazeOver also exposes `intensity` (0–100), `color`, and
`duration` via AppleScript if you want to tune the dimming.

### Optional: Do Not Disturb

macOS doesn't let scripts create Shortcuts, so create two by hand (15 seconds each) in the
**Shortcuts** app, each with a single **Set Focus** action:

- `Focus On`  → turn Do Not Disturb **on**
- `Focus Off` → turn Do Not Disturb **off**

`focus` runs them automatically if they exist.

### Permissions

The sentinel reads the local macOS notifications database, which requires **Full Disk
Access** (System Settings → Privacy & Security → Full Disk Access).

macOS attributes this permission to the **responsible process** — i.e. *whatever launches
the session* — so grant it to:

- **your terminal** (e.g. Ghostty, Terminal, iTerm) if you start sessions with `focus` on
  the command line, **and/or**
- **FocusBar.app** if you start sessions from the menu-bar app.

If the digest shows `Centinela sin acceso a la BD de notificaciones`, the process you
launched from is missing this grant.

> Note: FocusBar is ad-hoc signed, so macOS may ask you to re-grant Full Disk Access after
> you rebuild and re-sign the app.

Nothing leaves your machine except the notification text sent to your local `claude` CLI
for the urgency judgment.

## Usage

```bash
focus start 50 finish the payments endpoint   # 50-min session with a declared task
focus start                                    # no timer, no AI cleanup
focus status                                   # time elapsed / remaining
focus stop                                     # end early; shows the digest
focus scan <task>                              # dry-run: what AI would close, closes nothing
```

There's also a menu-bar app (`FocusBar`) with a live countdown and start/stop UI.

## How the sentinel decides

Three layers, cheapest first:

1. **Fixed rules** — known noise (download bots, sticker-only messages) is dropped instantly.
2. **Incident debounce** — a "new incident" alert waits 3 minutes; if its "auto-resolved"
   twin arrives, you never hear about it. Only real, unresolved incidents break through.
3. **LLM judgment** — everything else goes to Claude with your `~/.focusrc` rules and your
   declared task. When in doubt, it holds back. The only override is a whiff of a real
   health/safety/production emergency.

## Privacy

`~/.focusrc` (your personal rules) and all session/digest files stay local and are
gitignored. Notification text is sent only to your locally-installed `claude` CLI.

## License

MIT
