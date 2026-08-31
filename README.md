# llmactivity

Apple-Activity-style usage rings for the AI coding tools on your Mac: Claude Code, Codex, Cursor. Menu bar icons (one per tool), a popover with every limit and its reset time, and an optional desktop widget.

No login. It reads the credentials the tools already store locally and calls the same usage endpoints the tools use:

| Tool | Rings (outer → inner) | Credential |
|---|---|---|
| Claude Code | Weekly · model weekly (e.g. Fable) · 5h session | Keychain item `Claude Code-credentials` |
| Codex | 5h session · Weekly | `~/.codex/auth.json` |
| Cursor | API models · Auto (monthly cycle) | Cursor IDE token in `state.vscdb` |

A tool with no local login shows no icon.

## Build

```sh
swift build -c release
.build/release/LLMActivity --dump        # print live limits and exit
.build/release/LLMActivity --parsecheck  # parser self-test
.build/release/LLMActivity --show-popover # open the popover 3s after launch (for screenshots)
scripts/make-app.sh 0.1.0                # LLMActivity.app (ad-hoc signed)
scripts/make-dmg.sh 0.1.0
```

Not notarized: on first launch right-click → Open, or `xattr -cr /Applications/LLMActivity.app`.

## Settings

In the popover: **Monochrome icons** (template images, like the system icons) and **Desktop widget**. Poll interval: `defaults write com.chocksy.llmactivity pollInterval 30` (seconds, min 15).

## Known limits

No token refresh: if a tool's token expired, the icon dims and the popover says so; open that tool once.
