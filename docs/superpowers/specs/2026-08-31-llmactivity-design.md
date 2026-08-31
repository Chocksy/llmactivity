# llmactivity — design spec

Apple-Activity-style usage rings for the AI coding tools installed on this Mac: Claude Code, Codex, Cursor. macOS menu bar app plus an optional desktop widget. Swift, SwiftPM only, no Xcode project. Mirrors the structure and packaging of `deye-widget`.

Mockup: `design/mockup.html` (approved 2026-08-31).

## Goals

- At a glance: one ring stack per installed tool, one ring per billing window that tool has.
- Weekly limits matter as much as 5h limits. Every window is a ring, not just the session one.
- Zero login. Reuse the credentials the tools already store on the Mac.
- Flat memory and ~0% idle CPU over weeks of uptime (lesson from deye-widget).

## Non-goals (MVP)

- Token refresh. If a token is expired, show the tool as stale and tell the user to open the tool once.
- Cost/spend tracking, history charts, notifications.
- Windows/Linux.

## Providers

| Provider | Installed when | Credential | Endpoint | Rings (outer → inner) |
|---|---|---|---|---|
| Claude Code | Keychain item `Claude Code-credentials` exists | `claudeAiOauth.accessToken` from the keychain JSON | `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20` | `weekly_all` "Weekly", `weekly_scoped` "<scope.model.display_name> weekly" (e.g. Fable), `session` "5h session". Source: `limits[]`, fields `kind`, `percent`, `resets_at`. |
| Codex | `~/.codex/auth.json` exists | `tokens.access_token`, `tokens.account_id` | `GET https://chatgpt.com/backend-api/wham/usage`, headers `Authorization: Bearer`, `ChatGPT-Account-Id` | `rate_limit.primary_window` "5h session", `rate_limit.secondary_window` "Weekly". Fields `used_percent`, `reset_at` (unix seconds). Window labels derived from `limit_window_seconds` (18000 → "5h", 604800 → "Weekly"). |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` exists and holds `cursorAuth/accessToken` | JWT from `ItemTable` key `cursorAuth/accessToken`; user id = JWT `sub` after the `|` | `GET https://cursor.com/api/usage-summary`, header `Cookie: WorkosCursorSessionToken=<userId>%3A%3A<jwt>` | `individualUsage.plan.apiPercentUsed` "API models", `individualUsage.plan.autoPercentUsed` "Auto". Reset = `billingCycleEnd`. |

All three verified live on 2026-08-31 with the current local credentials.

Cursor's `state.vscdb` is 2.2 GB and locked by the IDE. Open it with the system SQLite (`import SQLite3`) read-only via URI `file:<path>?immutable=1`. Never copy it.

Colors: Claude `#e8845c`, Codex `#34d399`, Cursor `#a78bfa`. Inner rings are the same hue blended toward white (shade 0.75, 0.5). Track = ring color at 22% opacity.

## Data model

```swift
struct UsageLimit { let label: String; let percent: Double; let resetsAt: Date? }
struct ProviderUsage {
    let provider: Provider          // .claude, .codex, .cursor
    var limits: [UsageLimit]        // outer → inner, may be empty before first fetch
    var fetchedAt: Date?
    var error: String?              // non-nil = stale; keep last good limits
}
enum Provider: CaseIterable { case claude, codex, cursor
    var name: String; var color: NSColor; var isInstalled: Bool
    func fetch() async throws -> [UsageLimit]
}
```

## Components (one file each, `Sources/LLMActivity/`)

- `main.swift`: accessory app (`.accessory` activation policy), App Nap opt-out (`ProcessInfo.beginActivity`), CLI flags `--dump` (fetch every installed provider once, print limits, exit) and `--parsecheck` (run parsers against embedded fixture JSON, assert ring values, exit 0/1). Builds `Poller`, `StatusBarController`, `WidgetWindow`.
- `Providers.swift`: `Provider` enum, credential readers, the three fetch+parse functions. Parsers are pure functions `static func parse(_ data: Data) throws -> [UsageLimit]` so `--parsecheck` can drive them.
- `Poller.swift`: `@MainActor final class Poller: ObservableObject`, `@Published var usages: [ProviderUsage]` (installed providers only, fixed order Claude, Codex, Cursor). `refresh()` runs all fetches concurrently (`async let`), 15 s timeout each, keeps last good limits on error and sets `error`. A `Timer` every `Settings.pollInterval` seconds (default 60). Also refreshes on wake (`NSWorkspace.didWakeNotification`).
- `RingStack.swift`: SwiftUI view. `RingStack(color:, percents: [Double], lineWidth:, gap:)`. Each ring = `Circle().trim(from: 0, to: p).stroke(style: .init(lineWidth:, lineCap: .round)).rotationEffect(-90°)` over a 22%-opacity track. `.animation(.easeOut(duration: 0.9), value: percents)`. No `Canvas`, no `TimelineView`, no timers: Core Animation runs the one-shot fill, the app does nothing per frame. Also `static func image(color:, percents:, size:, monochrome:) -> NSImage` via `ImageRenderer`, called only when data changes. Monochrome = rings drawn black, tracks black at 25% opacity, `isTemplate = true`.
- `StatusBar.swift`: one `NSStatusItem` per installed provider (fixed 22 pt). Button image = `RingStack.image(size: 18)`, refreshed from `poller.$usages` and `settings.$monochrome`. Stale provider → image `alphaValue = 0.5`. Left click on any icon opens one shared `NSPopover` (`.transient`) anchored at that icon, hosting `PopoverView`.
- `PopoverView.swift`: as in the mockup. Header (title, "Updated Xs ago"). One row per provider: 110 pt ring stack left; name, one line per limit (`label · resets in Xh` and percent) right. Stale row shows the error in muted text below the name. Footer: toggles **Monochrome icons**, **Desktop widget**; buttons **Refresh**, **Quit**.
- `WidgetWindow.swift`: copied from deye-widget (borderless, desktop-icon level +1, all Spaces, vibrancy with rounded mask, drag anywhere, remembered position, pin-to-screen logic kept minimal: primary screen only for MVP). Hosts `WidgetView`: the ring stacks side by side, tool name, percents. Shown/hidden by the Desktop widget toggle.
- `Settings.swift`: `ObservableObject` over `UserDefaults`: `monochrome: Bool` (false), `showWidget: Bool` (false), `pollInterval: Int` (60), `widgetOrigin: CGPoint?`.

## Data flow

`Timer` → `Poller.refresh()` → three concurrent fetches → `usages` published → SwiftUI views animate trims; `StatusBarController` re-renders three 18 pt images. Nothing else runs between polls.

## Error handling

- Provider not installed: not in `usages`, no icon, no row.
- HTTP 401/403 or JSON without expected keys: `error = "Token expired, open <tool> once"` / `"Unexpected response"`. Last good rings stay, icon dims.
- Network error: `error = "Offline"`, same behavior.
- Keychain read denied: treat Claude as installed with `error = "Keychain access denied"`.

## Performance rules (from deye-widget v1.4.0)

- No per-frame app work. No `Canvas` redraw loops, no `TimelineView`, no display-link timers.
- Status bar images rendered only on data or settings change (max 3 images per poll).
- One `URLSession` shared; no retained closures capturing `self` strongly in timers (`[weak self]`).

## Testing

- `--parsecheck`: embedded fixture JSON for all three providers (captured 2026-08-31, PII scrubbed) → parser output must equal the expected `[UsageLimit]` (labels, percents, reset dates). Exit 1 on mismatch. This is the one runnable check.
- `--dump`: manual live smoke test.
- Visual: run the app, confirm three icons, popover rows, widget; toggle monochrome; unplug network and confirm dimmed icon + stale text.

## Packaging

`Package.swift` (macOS 13, single executable target `LLMActivity`), `scripts/make-app.sh` + `scripts/Info.plist.template` (`LSUIElement = true`) + `scripts/make-dmg.sh` copied from deye-widget with names swapped. Icon: placeholder `assets/icon-1024.png` generated from the ring stack. GitHub Actions release on tag, same workflow as deye-widget.

## Later (not now)

- Token refresh for Claude and Codex.
- More providers (Gemini CLI, GitHub Copilot).
- Notification when a ring crosses 80% / 100%.
- Widget pin-to-screen picker.
