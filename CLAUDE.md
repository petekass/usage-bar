# UsageBar - Project Instructions

## Overview

macOS menu bar app displaying Claude Code, Codex, and Gemini usage limits. Native Swift/SwiftUI app using NSPanel for the popup.

## Build Commands

```bash
# Debug build
swift build

# Release build
swift build -c release

# Run (menu bar app)
./.build/release/UsageBar

# Run in a terminal (ANSI output, refreshes every 60s; --once for a single snapshot)
./.build/release/UsageBar --cli

# Install CLI copy used by the cmux Dock control (~/.config/cmux/dock.json)
cp ./.build/release/UsageBar ~/.local/bin/usagebar

# Install the menu bar app: copy the binary into the bundle, then re-sign.
cp ./.build/release/UsageBar /Applications/UsageBar.app/Contents/MacOS/UsageBar
codesign --force --sign "Apple Development: peter.kassi@icloud.com (LSN94AS8XC)" /Applications/UsageBar.app
```

## Project Structure

```
UsageBar/
├── Package.swift          # Swift Package manifest (macOS 14+)
├── Sources/
│   ├── UsageBar.swift     # Main app (all code in single file)
│   └── Info.plist         # App metadata (LSUIElement for menu bar)
└── usage.5m.sh            # Alternative SwiftBar/xbar plugin
```

## Architecture

- **Single-file app**: Everything in `UsageBar.swift` for simplicity
- **No dependencies**: Pure SwiftUI + AppKit
- **NSPanel**: Non-activating floating panel for the popup
- **Async/await**: Modern Swift concurrency for API calls

## API Endpoints

- Claude: `api.anthropic.com/api/oauth/usage`. Bearer token in this order: `~/.config/usagebar/token`, unexpired `~/.claude/.credentials.json`, then Claude Code's Keychain item `Claude Code-credentials`, read via `/usr/bin/security find-generic-password` (never `SecItemCopyMatching`: the item's ACL trusts `/usr/bin/security`, so only that path avoids authorization prompts). Never touch the refresh token.
- Claude local fallback: `~/.claude/usage-cache.json` (fresh statusline data, no authentication required)
- Codex: `chatgpt.com/backend-api/wham/usage` (Bearer token from `~/.codex/auth.json`)
- Gemini: `daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` (5h, 7d, and model-scoped limits such as Argon; requires `User-Agent: antigravity/acp/...`) with fallback to `retrieveUserQuota` (free tier / Gemini CLI). Bearer token in this order: `~/.config/usagebar/gemini-token`, unexpired T3 Antigravity token `~/.t3/userdata/providers/antigravity/*/antigravity-acp/antigravity-oauth-token`, Antigravity CLI Keychain item (`-s gemini -a antigravity`, read via `/usr/bin/security`), then `~/.gemini/oauth_creds.json`. When every Antigravity access token is expired, UsageBar mints its own from the Antigravity refresh token (`oauth2.googleapis.com/token`, client from `~/.config/usagebar/gemini-oauth-client.json`, never committed: the repo is public) and keeps it in memory only; never write back to T3's file or the Keychain. Google does not rotate the refresh token on this grant, so T3 and `agy` stay logged in. Claude and Codex rotate refresh tokens, so their refresh flow stays with Claude Code / Codex.
- When a fetch fails, the last good data stays visible with a runtime-only `staleReason` ("Auth expired", "Rate limit", ...) next to the "as of" label; it is never written to the shared cache.

## Code Style

- Keep everything in single file unless it grows significantly
- Use Swift standard patterns (MARK comments, structs for data)
- Minimal error handling - show "No auth" or "Error" in UI
- Color thresholds: green <60%, orange 60-80%, red >=80%

## Testing

Manual testing only - run the app and verify:
1. Icon appears in menu bar
2. Clicking shows panel with usage data
3. Clicking outside closes panel
4. Refresh button updates data
