# UsageBar

A lightweight macOS menu bar app that displays your Claude Code and OpenAI Codex usage at a glance.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- **Menu Bar Integration**: Minimal footprint with a single icon in your menu bar
- **Claude Code Usage**: Shows 5-hour session and 7-day weekly limits
- **Codex Usage**: Shows primary and secondary rate limit windows
- **Reset Timers**: See when your limits will reset
- **Color-coded Progress**: Green/Orange/Red indicators based on usage level

## Screenshots

*Click the ⚡ icon in your menu bar to see your current usage:*

```
┌──────────────────────────────┐
│ Usage                      ↻ │
├──────────────────────────────┤
│ Claude                       │
│ 5h  ████████░░  42%    3h    │
│ 7d  ██████░░░░  28%    4d    │
│                              │
│ Codex                        │
│ 5h  ██░░░░░░░░  12%    4h    │
│ 7d  █░░░░░░░░░   5%    6d    │
├──────────────────────────────┤
│ 14:32                   Quit │
└──────────────────────────────┘
```

## Requirements

- macOS 14.0 (Sonoma) or later
- Active Claude Code subscription (for Claude usage)
- Active Codex subscription (for Codex usage)

## Installation

### Build from Source

```bash
git clone https://github.com/petekass/usage-bar.git
cd usage-bar
swift build -c release
cp .build/release/UsageBar /usr/local/bin/
```

### Run Directly

```bash
swift build -c release
./.build/release/UsageBar &
```

## Setup

UsageBar needs no setup for Claude Code on macOS beyond being signed in to
Claude Code.

### Claude Code

UsageBar calls the Claude OAuth usage API with Claude Code's own access token,
which Claude Code keeps in the login Keychain (`Claude Code-credentials`).
UsageBar reads that item through `/usr/bin/security`, the same tool Claude Code
uses to read and write it. The item's access list trusts that tool, so the read
shows no authorization prompt, works the same for the app bundle and the
`--cli` copy, and survives token rotations. UsageBar only uses the access token;
refreshing it stays with Claude Code, so the data is live while any Claude Code
session (terminal, IDE or SDK) keeps the login fresh.

Other sources, in order of precedence:

- `~/.config/usagebar/token` (0600): an optional dedicated token that overrides
  the Keychain item.
- An unexpired `~/.claude/.credentials.json`, where Claude Code stores
  credentials on Linux.
- `~/.claude/usage-cache.json`, written by the Claude Code statusline script
  (see below); accepted up to 15 minutes old. This source has no model-scoped
  rows and is only written while an interactive terminal session renders its
  statusline.

When no source is fresh, the panel keeps the last good data, dimmed and labelled
"as of HH:mm" (with the date once it is older than a day).

### Codex (OpenAI)

Authenticate with Codex CLI first. This creates `~/.codex/auth.json`.

## SwiftBar / xbar Integration

An alternative shell script `usage.5m.sh` is included for use with [SwiftBar](https://github.com/swiftbar/SwiftBar) or [xbar](https://xbarapp.com/).

1. Copy `usage.5m.sh` to your SwiftBar/xbar plugins directory
2. Make it executable: `chmod +x usage.5m.sh`
3. Populate the cache file `~/.claude/usage-cache.json` from a cron job or launchd agent

The cache file must follow this format:

```json
{
  "claude_weekly": "28",
  "claude_session": "42",
  "weekly_reset": "1712419200",
  "session_reset": "1712332800",
  "ts": 1712330000
}
```

- `claude_weekly` / `claude_session`: percent used (0–100), encoded as strings
- `weekly_reset` / `session_reset`: Unix timestamps encoded as strings
- `ts`: numeric Unix timestamp for when the cache was written

## How It Works

1. Calls the Claude OAuth usage API with Claude Code's Keychain token (or a token file)
2. Falls back to fresh Claude usage from `~/.claude/usage-cache.json`
3. Reads Codex OAuth tokens from `~/.codex/auth.json`
4. Calls the Codex usage API: `chatgpt.com/backend-api/wham/usage`
5. Refreshes usage automatically and displays percentages and reset timers in a floating panel

> **⚠️ Note on API stability**
> Both endpoints are **undocumented / internal APIs** used by the official CLIs.
> They may change or disappear without notice. If UsageBar shows "API error"
> after a CLI update, the payload shape or endpoint may have changed.

## Auto-Start

To launch UsageBar automatically on login:

1. Build the release binary
2. Add it to Login Items in System Settings → General → Login Items

Or create a LaunchAgent:

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/io.github.peterflowset.usagebar.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.peterflowset.usagebar</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/UsageBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
launchctl load ~/Library/LaunchAgents/io.github.peterflowset.usagebar.plist
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.
