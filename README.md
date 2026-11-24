# Sundial

A lightweight, native macOS time tracker in the spirit of [WakaTime](https://wakatime.com), with no editor plugins and nothing sent anywhere. It lives in the menu bar, notes every few seconds which app is in front and what it shows, and adds the time up by project. Clicking its menu bar item, which shows today's total, opens a panel with the overview.

- Every 5 seconds, records the front app and the file, folder or page it shows, and works out the Git repository it belongs to
- Stops counting when the screen is locked or asleep, when recording is paused, or after 3 minutes without keyboard or mouse input (10 minutes in apps you mostly read in)
- The panel shows, for the last 7 or 30 days, your total, today's time, the daily average and the most active day; each project's time as ranked bars with its share; each project's day-by-day trend as small charts on one scale; and a day's timeline, one row per project across its 24 hours, a day at a time. Each project keeps its own color everywhere, across periods and launches, from the eight-color palette of Claude Code's dataviz skill
- Click a project for its time per agent, per app and per file, folder or page; "Other Projects" lists the rest, including projects only agents worked on
- Records how long coding agents work, through their hooks: [Claude Code](https://github.com/anthropics/claude-code), [Codex](https://github.com/openai/codex) and [Antigravity CLI](https://antigravity.google) — kept apart from your own time, since agents run while you do other things
- The ⋯ menu at the bottom of the panel pauses recording, turns Open at Login on or off, and quits
- Opens at login
- Written in Swift with SwiftUI only — no Electron, no dependencies

## What it reads

| App | How | What |
|---|---|---|
| [Ghostty](https://ghostty.org) | AppleScript | Working directory of the focused terminal |
| Brave | AppleScript | Address of the active tab; on github.com, the repository counts as the project |
| Any other app | Accessibility API | Document (file) and title of the focused window |

The project is the Git repository holding the file or directory, found by looking for `.git` up to the home folder. A linked worktree counts as its main repository, and project names are matched without regard to case, so the GitHub repository `rejoin` joins the local folder `Rejoin`.

Sundial needs two kinds of permission, which macOS asks for the first time they are used:

- **Accessibility**, to read the document of the focused window. Without it, only app names are recorded.
- **Automation** for Ghostty and Brave, to read the working directory and the address.

Sundial is signed ad hoc, so macOS treats every new build as a new app, and turning the old entry off and on again doesn't carry the permission over. After rebuilding, remove Sundial from System Settings › Privacy & Security › Accessibility with − (or run `tccutil reset Accessibility local.sundial`), then open Sundial and allow it again.

## Agents

`Sundial agent <tool>` reads a hook's JSON on stdin and records the agent's turn, from your prompt until it stops, under the project of the agent's working directory. It takes about 10 ms and prints `{}`. Point each tool's hooks at the binary inside the app:

| Tool | File | Events |
|---|---|---|
| Claude Code | `~/.claude/settings.json` (`hooks`) | `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SessionEnd` |
| Codex | `~/.codex/hooks.json` | `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop` |
| Antigravity CLI | `~/.gemini/config/hooks.json` | `PreInvocation`, `PreToolUse`, `PostToolUse`, `Stop` |

For example, in `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/Applications/Sundial.app/Contents/MacOS/Sundial agent codex" }] }],
    "PreToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/Applications/Sundial.app/Contents/MacOS/Sundial agent codex" }] }],
    "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/Applications/Sundial.app/Contents/MacOS/Sundial agent codex" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "~/Applications/Sundial.app/Contents/MacOS/Sundial agent codex" }] }]
  }
}
```

The tool name (`claude`, `codex`, `antigravity`) is what Sundial shows. A prompt starts a turn and `Stop` ends it; tool use and model calls move its end forward, so a turn cut short without `Stop` ends at its last activity, and `SessionEnd` closes it without moving its end. A tool still running keeps the turn going for up to an hour; otherwise 10 minutes without any event means the agent sat idle, and the next event starts a new turn. Hooks can't tell when you answer a permission prompt, so time spent waiting for you while a tool asks counts as agent time, up to that hour. Antigravity CLI sends no prompt event, so its turns start with any event. Codex runs new hooks only after you trust them in Codex.

Everything is kept in `~/Library/Application Support/Sundial/sundial.sqlite` and never leaves your Mac.

## Requirements

- macOS 26 or later
- Xcode or the Xcode Command Line Tools (Swift 6)

## Build

```sh
./build.sh
```

This produces `build/Sundial.app`. `./build.sh --install` also copies it to `~/Applications`.

The app icon is drawn by `scripts/make-icon.swift` at build time. UI strings are English in code; other languages live in `Localization/*.lproj`.

## License

MIT
