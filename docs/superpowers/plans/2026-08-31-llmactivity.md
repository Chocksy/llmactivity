# llmactivity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu bar app (plus optional desktop widget) that shows Apple-Activity-style usage rings for Claude Code, Codex and Cursor, read from the credentials those tools already store on the Mac.

**Architecture:** Single SwiftPM executable target. `Providers.swift` reads local credentials and fetches/parses each tool's usage endpoint into `[UsageLimit]`. `Poller` refreshes all installed providers every 60 s and publishes `[ProviderUsage]`. SwiftUI `RingStack` draws the rings (trim-animated, no per-frame work); `StatusBarController` shows one `NSStatusItem` per provider and a shared popover; `WidgetWindow` (copied from deye-widget) hosts the same rings on the desktop.

**Tech Stack:** Swift 5.9 language mode on the Swift 6.3 toolchain, SwiftPM only (no Xcode project), AppKit + SwiftUI, Foundation `URLSession`, system `SQLite3` module, `/usr/bin/security` for Keychain reads.

**Spec:** `docs/superpowers/specs/2026-08-31-llmactivity-design.md`

## Global Constraints

- macOS 13+ (`platforms: [.macOS(.v13)]`), `// swift-tools-version:5.9`.
- No third-party dependencies. No Xcode project.
- No per-frame app work: no `Canvas` redraw loops, no `TimelineView`, no display-link timers. Status bar images are rendered only when data or settings change.
- Cursor's `state.vscdb` (2.2 GB) is opened in place, read-only. Never copied.
- Timer and notification closures capture `self` weakly.
- Colors: Claude `#e8845c`, Codex `#34d399`, Cursor `#a78bfa`. Inner rings blend toward white; tracks at 22% opacity.
- Provider order everywhere: Claude, Codex, Cursor.
- Commit after every task with the message given in the task. Work on `main`.
- Reference implementation to copy patterns from (read before editing): `/Volumes/External/Development/deye-widget/Sources/DeyeWidget/{main.swift,StatusBar.swift,WidgetWindow.swift,Settings.swift}` and `/Volumes/External/Development/deye-widget/scripts/*`.

---

### Task 1: Package skeleton and data model

**Files:**
- Create: `Package.swift`
- Create: `Sources/LLMActivity/Model.swift`
- Create: `Sources/LLMActivity/main.swift` (placeholder, replaced in Task 5)

**Interfaces:**
- Produces: `struct UsageLimit`, `struct ProviderUsage`, `enum ProviderError`, used by every later task.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LLMActivity",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LLMActivity",
            path: "Sources/LLMActivity",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
```

- [ ] **Step 2: Write `Sources/LLMActivity/Model.swift`**

```swift
import Foundation

/// One billing window of one provider. `percent` is 0...100 used.
struct UsageLimit: Equatable {
    let label: String
    let percent: Double
    let resetsAt: Date?
}

/// Latest known state of one provider. On fetch failure the last good
/// `limits` stay and `error` is set, so the UI can show stale-but-useful data.
struct ProviderUsage: Identifiable {
    let provider: Provider
    var limits: [UsageLimit] = []
    var fetchedAt: Date? = nil
    var error: String? = nil
    var id: Provider { provider }
    var isStale: Bool { error != nil }
}

/// Stub so Task 1 builds; Task 2 replaces it with the real enum in Providers.swift.
enum Provider: String, CaseIterable, Identifiable {
    case claude, codex, cursor
    var id: String { rawValue }
}

enum ProviderError: Error, CustomStringConvertible {
    case notInstalled
    case auth(String)          // missing / expired credential; message tells the user what to do
    case http(Int)
    case unexpected(String)    // response did not have the fields we parse

    var description: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .auth(let m): return m
        case .http(let code): return code == 401 || code == 403 ? "Token expired, open the tool once" : "HTTP \(code)"
        case .unexpected(let m): return "Unexpected response: \(m)"
        }
    }
}

// MARK: - Date helpers shared by the parsers

enum DateParse {
    /// Parses ISO-8601 with any number of fractional-second digits
    /// (Anthropic sends microseconds, Cursor sends milliseconds).
    static func iso(_ any: Any?) -> Date? {
        guard var s = any as? String else { return nil }
        if let dot = s.firstIndex(of: ".") {
            // drop ".123456" but keep the zone suffix ("+00:00" or "Z")
            let after = s[dot...]
            let zoneStart = after.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) ?? after.endIndex
            s = String(s[..<dot]) + String(after[zoneStart...])
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
    static func unix(_ any: Any?) -> Date? {
        (any as? Double).map { Date(timeIntervalSince1970: $0) }
    }
}
```

- [ ] **Step 3: Write placeholder `Sources/LLMActivity/main.swift`**

```swift
import Foundation
print("llmactivity")
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources
git commit -m "Package skeleton and usage model"
```

---

### Task 2: Providers, credential readers, parsers, `--parsecheck`

**Files:**
- Create: `Sources/LLMActivity/Providers.swift`
- Create: `Sources/LLMActivity/Fixtures.swift`
- Modify: `Sources/LLMActivity/main.swift`

**Interfaces:**
- Consumes: `UsageLimit`, `ProviderError`, `DateParse` (Task 1).
- Produces: `enum Provider: String, CaseIterable, Identifiable` with `name`, `shortName`, `color: NSColor`, `isInstalled: Bool`, `func fetch(session: URLSession) async throws -> [UsageLimit]`, and static pure parsers `parseClaude(_:)`, `parseCodex(_:)`, `parseCursor(_:)`. `func runParseCheck() -> Int32`, `func runDump() -> Int32`.

- [ ] **Step 1: Write the failing check first: `Sources/LLMActivity/Fixtures.swift`**

Embed the three files under `design/fixtures/*.json` verbatim as the string literals (copy the file contents exactly; they are the scrubbed live responses from 2026-08-31).

```swift
import Foundation

enum Fixtures {
    static let claude = #"""
    <paste design/fixtures/claude.json verbatim>
    """#
    static let codex = #"""
    <paste design/fixtures/codex.json verbatim>
    """#
    static let cursor = #"""
    <paste design/fixtures/cursor.json verbatim>
    """#
}

/// `--parsecheck`: the one runnable check. Drives the pure parsers with the
/// captured fixtures and asserts labels, percents (rounded) and reset dates.
func runParseCheck() -> Int32 {
    var pass = true
    func check(_ name: String, _ got: [UsageLimit], _ want: [(String, Int, String?)]) {
        let gotRows = got.map { ($0.label, Int($0.percent.rounded()), $0.resetsAt.map { ISO8601DateFormatter().string(from: $0) }) }
        let ok = gotRows.count == want.count && zip(gotRows, want).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
        pass = pass && ok
        print("  \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(ok ? "PASS" : "FAIL")")
        if !ok { print("    got:  \(gotRows)"); print("    want: \(want)") }
    }
    print("=== Parser self-test ===")
    do {
        check("claude", try Provider.parseClaude(Data(Fixtures.claude.utf8)), [
            ("Weekly", 7, "2026-09-07T07:59:59Z"),
            ("Fable weekly", 7, "2026-09-07T07:59:59Z"),
            ("5h session", 48, "2026-08-31T15:49:59Z"),
        ])
        check("codex", try Provider.parseCodex(Data(Fixtures.codex.utf8)), [
            ("5h session", 62, "2026-08-31T18:08:24Z"),
            ("Weekly", 38, "2026-09-07T13:08:24Z"),
        ])
        check("cursor", try Provider.parseCursor(Data(Fixtures.cursor.utf8)), [
            ("API models", 71, "2026-09-22T08:37:25Z"),
            ("Auto", 15, "2026-09-22T08:37:25Z"),
        ])
        // Garbage must throw, not crash or return empty.
        do { _ = try Provider.parseClaude(Data("{}".utf8)); print("  empty    FAIL (no throw)"); pass = false }
        catch { print("  empty    PASS") }
    } catch {
        print("  threw: \(error)"); pass = false
    }
    print(pass ? "ALL PASS" : "FAIL")
    return pass ? 0 : 1
}
```

Codex expected dates come from the fixture: `reset_at` 1788199704 → `2026-08-31T18:08:24Z`, 1788786504 → `2026-09-07T13:08:24Z` (verified with `date -u -r`).

- [ ] **Step 2: Wire `--parsecheck` into `main.swift` and run it to see it fail**

```swift
import Foundation
if CommandLine.arguments.contains("--parsecheck") { exit(runParseCheck()) }
print("llmactivity")
```

Run: `swift build 2>&1 | grep -E "error|Build complete" | head`
Expected: compile errors: `Provider` not defined.

- [ ] **Step 3: Write `Sources/LLMActivity/Providers.swift`** and delete the `enum Provider` stub from `Model.swift` (the real enum below replaces it).

```swift
import AppKit
import Foundation
import SQLite3

enum Provider: String, CaseIterable, Identifiable {
    case claude, codex, cursor

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }
    var color: NSColor {
        switch self {
        case .claude: return NSColor(srgbRed: 0xE8 / 255, green: 0x84 / 255, blue: 0x5C / 255, alpha: 1)
        case .codex: return NSColor(srgbRed: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255, alpha: 1)
        case .cursor: return NSColor(srgbRed: 0xA7 / 255, green: 0x8B / 255, blue: 0xFA / 255, alpha: 1)
        }
    }

    /// "Installed" = the tool left credentials on this Mac.
    var isInstalled: Bool {
        switch self {
        case .claude: return ClaudeAuth.rawJSON() != nil
        case .codex: return FileManager.default.fileExists(atPath: CodexAuth.path)
        case .cursor: return FileManager.default.fileExists(atPath: CursorAuth.dbPath)
        }
    }

    // MARK: Fetch

    func fetch(session: URLSession) async throws -> [UsageLimit] {
        var req: URLRequest
        switch self {
        case .claude:
            let token = try ClaudeAuth.accessToken()
            req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        case .codex:
            let (token, account) = try CodexAuth.credentials()
            req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let account { req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        case .cursor:
            let jwt = try CursorAuth.accessToken()
            let uid = try CursorAuth.userID(jwt: jwt)
            req = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
            req.setValue("WorkosCursorSessionToken=\(uid)%3A%3A\(jwt)", forHTTPHeaderField: "Cookie")
        }
        req.setValue("llmactivity", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ProviderError.http(code) }
        switch self {
        case .claude: return try Self.parseClaude(data)
        case .codex: return try Self.parseCodex(data)
        case .cursor: return try Self.parseCursor(data)
        }
    }

    // MARK: Parsers (pure; driven by --parsecheck)

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.unexpected("not a JSON object")
        }
        return o
    }

    /// Rings outer→inner: weekly_all, weekly_scoped (model name), session.
    static func parseClaude(_ data: Data) throws -> [UsageLimit] {
        let root = try json(data)
        guard let limits = root["limits"] as? [[String: Any]] else { throw ProviderError.unexpected("no limits[]") }
        func find(_ kind: String) -> [String: Any]? { limits.first { $0["kind"] as? String == kind } }
        func pct(_ l: [String: Any]) -> Double { (l["percent"] as? Double) ?? 0 }
        var out: [UsageLimit] = []
        if let l = find("weekly_all") {
            out.append(UsageLimit(label: "Weekly", percent: pct(l), resetsAt: DateParse.iso(l["resets_at"])))
        }
        if let l = find("weekly_scoped") {
            let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String ?? "Model"
            out.append(UsageLimit(label: "\(model) weekly", percent: pct(l), resetsAt: DateParse.iso(l["resets_at"])))
        }
        if let l = find("session") {
            out.append(UsageLimit(label: "5h session", percent: pct(l), resetsAt: DateParse.iso(l["resets_at"])))
        }
        guard !out.isEmpty else { throw ProviderError.unexpected("no known limit kinds") }
        return out
    }

    /// Rings outer→inner: primary_window (5h), secondary_window (weekly).
    static func parseCodex(_ data: Data) throws -> [UsageLimit] {
        let root = try json(data)
        guard let rl = root["rate_limit"] as? [String: Any] else { throw ProviderError.unexpected("no rate_limit") }
        var out: [UsageLimit] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = rl[key] as? [String: Any] else { continue }
            let secs = (w["limit_window_seconds"] as? Double) ?? 0
            let label = secs >= 6 * 86400 ? "Weekly" : "\(max(1, Int(secs / 3600)))h session"
            out.append(UsageLimit(label: label, percent: (w["used_percent"] as? Double) ?? 0, resetsAt: DateParse.unix(w["reset_at"])))
        }
        guard !out.isEmpty else { throw ProviderError.unexpected("no rate windows") }
        return out
    }

    /// Rings outer→inner: API models, Auto. Both reset at billingCycleEnd.
    static func parseCursor(_ data: Data) throws -> [UsageLimit] {
        let root = try json(data)
        guard let plan = (root["individualUsage"] as? [String: Any])?["plan"] as? [String: Any] else {
            throw ProviderError.unexpected("no individualUsage.plan")
        }
        let end = DateParse.iso(root["billingCycleEnd"])
        return [
            UsageLimit(label: "API models", percent: (plan["apiPercentUsed"] as? Double) ?? 0, resetsAt: end),
            UsageLimit(label: "Auto", percent: (plan["autoPercentUsed"] as? Double) ?? 0, resetsAt: end),
        ]
    }
}

// MARK: - Credential readers

enum ClaudeAuth {
    /// Reads the Keychain item Claude Code writes, via /usr/bin/security so the
    /// Keychain prompt (if any) is attributed to `security`, which the user has
    /// already approved by using Claude Code. Returns nil if the item is missing.
    static func rawJSON() -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func accessToken() throws -> String {
        guard let root = rawJSON() else { throw ProviderError.auth("No Claude Code login in Keychain") }
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ProviderError.auth("Claude Code Keychain item has no accessToken")
        }
        if let exp = oauth["expiresAt"] as? Double, exp / 1000 < Date().timeIntervalSince1970 {
            throw ProviderError.auth("Token expired, run `claude` once")
        }
        return token
    }
}

enum CodexAuth {
    static var path: String { NSHomeDirectory() + "/.codex/auth.json" }

    static func credentials() throws -> (token: String, accountID: String?) {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw ProviderError.auth("No Codex login in ~/.codex/auth.json")
        }
        return (token, tokens["account_id"] as? String)
    }
}

enum CursorAuth {
    static var dbPath: String {
        NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    /// Reads cursorAuth/accessToken from the IDE's state DB in place. First a
    /// normal read-only open (sees WAL content, i.e. the freshest token); if
    /// the IDE's locks get in the way, retry with immutable=1 (main file only).
    static func accessToken() throws -> String {
        if let t = try? query(immutable: false) { return t }
        return try query(immutable: true)
    }

    private static func query(immutable: Bool) throws -> String {
        let encoded = dbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dbPath
        let uri = "file:\(encoded)?mode=ro" + (immutable ? "&immutable=1" : "")
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw ProviderError.auth("Cannot open Cursor state.vscdb")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1, &stmt, nil) == SQLITE_OK else {
            throw ProviderError.auth("Cursor state.vscdb: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else {
            throw ProviderError.auth("Not logged in to Cursor")
        }
        let token = String(cString: c)
        guard !token.isEmpty else { throw ProviderError.auth("Not logged in to Cursor") }
        return token
    }

    /// The cookie needs `<userId>::<jwt>`; userId is the JWT `sub` after "auth0|".
    static func userID(jwt: String) throws -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { throw ProviderError.auth("Cursor token is not a JWT") }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = obj["sub"] as? String else {
            throw ProviderError.auth("Cursor token has no sub")
        }
        return sub.split(separator: "|").last.map(String.init) ?? sub
    }
}

// MARK: - --dump (live smoke test)

func runDump() -> Int32 {
    let done = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task {
        for p in Provider.allCases {
            guard p.isInstalled else { print("\(p.name): not installed"); continue }
            do {
                let limits = try await p.fetch(session: .shared)
                print(p.name)
                for l in limits {
                    print("  \(l.label): \(Int(l.percent.rounded()))%  resets \(l.resetsAt.map { "\($0)" } ?? "-")")
                }
            } catch {
                print("\(p.name): ERROR \(error)")
                code = 1
            }
        }
        done.signal()
    }
    done.wait()
    return code
}
```

- [ ] **Step 4: Add `--dump` to `main.swift`**

```swift
import Foundation
if CommandLine.arguments.contains("--parsecheck") { exit(runParseCheck()) }
if CommandLine.arguments.contains("--dump") { exit(runDump()) }
print("llmactivity")
```

- [ ] **Step 5: Run the check and the live dump**

Run: `swift build 2>&1 | grep -E "error|warning: unre|Build complete" | head; .build/debug/LLMActivity --parsecheck`
Expected: `ALL PASS` (four PASS lines).

Run: `.build/debug/LLMActivity --dump`
Expected: three provider blocks with real percentages, exit 0. Claude shows `Weekly`, `Fable weekly`, `5h session`; Codex shows `5h session`, `Weekly`; Cursor shows `API models`, `Auto`.

- [ ] **Step 6: Commit**

```bash
git add Sources
git commit -m "Providers: Claude, Codex, Cursor fetch + parsers with --parsecheck and --dump"
```

---

### Task 3: Settings and Poller

**Files:**
- Create: `Sources/LLMActivity/Settings.swift`
- Create: `Sources/LLMActivity/Poller.swift`

**Interfaces:**
- Consumes: `Provider`, `ProviderUsage`, `UsageLimit`.
- Produces: `@MainActor final class Settings: ObservableObject` with `static let shared`, `@Published var monochrome: Bool`, `@Published var showWidget: Bool`, `var pollInterval: TimeInterval`. `@MainActor final class Poller: ObservableObject` with `@Published private(set) var usages: [ProviderUsage]`, `@Published private(set) var lastRefresh: Date?`, `func start(interval:)`, `func refresh() async`.

- [ ] **Step 1: Write `Settings.swift`**

```swift
import Foundation
import Combine

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var monochrome: Bool { didSet { d.set(monochrome, forKey: "monochrome") } }
    @Published var showWidget: Bool { didSet { d.set(showWidget, forKey: "showWidget") } }

    /// Seconds between polls. `defaults write com.chocksy.llmactivity pollInterval 30` to change; floor 15.
    var pollInterval: TimeInterval {
        let v = d.double(forKey: "pollInterval")
        return v == 0 ? 60 : max(15, v)
    }

    private init() {
        monochrome = d.bool(forKey: "monochrome")
        showWidget = d.bool(forKey: "showWidget")
    }
}
```

- [ ] **Step 2: Write `Poller.swift`**

```swift
import AppKit
import Combine
import Foundation

/// Refreshes every installed provider on a fixed interval and on wake.
/// Failures keep the last good limits and set `error` (stale state).
@MainActor
final class Poller: ObservableObject {
    @Published private(set) var usages: [ProviderUsage]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    private let session: URLSession
    private var timer: Timer?

    init(providers: [Provider]) {
        usages = providers.map { ProviderUsage(provider: $0) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        session = URLSession(configuration: cfg)
    }

    func start(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer?.tolerance = interval / 10
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let providers = usages.map(\.provider)
        let session = self.session
        let results: [(Provider, Result<[UsageLimit], Error>)] = await withTaskGroup(of: (Provider, Result<[UsageLimit], Error>).self) { group in
            for p in providers {
                group.addTask {
                    do { return (p, .success(try await p.fetch(session: session))) }
                    catch { return (p, .failure(error)) }
                }
            }
            var out: [(Provider, Result<[UsageLimit], Error>)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (p, r) in results {
            guard let i = usages.firstIndex(where: { $0.provider == p }) else { continue }
            switch r {
            case .success(let limits):
                usages[i].limits = limits
                usages[i].fetchedAt = Date()
                usages[i].error = nil
            case .failure(let e):
                usages[i].error = (e as? ProviderError)?.description
                    ?? ((e as? URLError) != nil ? "Offline" : e.localizedDescription)
            }
        }
        lastRefresh = Date()
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources
git commit -m "Settings and Poller"
```

---

### Task 4: RingStack view and status bar image rendering

**Files:**
- Create: `Sources/LLMActivity/RingStack.swift`

**Interfaces:**
- Produces: `struct RingStack: View` with `init(color: NSColor, percents: [Double], lineWidth: CGFloat = 12, gap: CGFloat = 3, monochrome: Bool = false)`; `@MainActor static func image(color: NSColor, percents: [Double], size: CGFloat, monochrome: Bool) -> NSImage`.

- [ ] **Step 1: Write `RingStack.swift`**

```swift
import AppKit
import SwiftUI

/// Concentric usage rings, outer ring first. Each ring is a 22%-opacity track
/// plus a trimmed, round-capped arc. The fill animates via SwiftUI's implicit
/// animation on `percents` (Core Animation does the work; the app draws nothing
/// per frame). Inner rings are the provider color blended toward white.
struct RingStack: View {
    let color: NSColor
    let percents: [Double]
    var lineWidth: CGFloat = 12
    var gap: CGFloat = 3
    var monochrome: Bool = false

    var body: some View {
        ZStack {
            ForEach(Array(percents.enumerated()), id: \.offset) { i, p in
                let inset = CGFloat(i) * (lineWidth + gap) + lineWidth / 2
                let c = ringColor(i)
                Circle()
                    .stroke(c.opacity(0.22), lineWidth: lineWidth)
                    .padding(inset)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(p, 0), 100) / 100))
                    .stroke(c, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(inset)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.easeOut(duration: 0.9), value: percents)
    }

    private func ringColor(_ i: Int) -> Color {
        if monochrome { return .black }
        let n = max(percents.count - 1, 1)
        let towardWhite = Double(i) / Double(n) * 0.5 * 0.55   // 0 for the outer ring, ~0.275 for the innermost of 3
        let ns = color.blended(withFraction: towardWhite, of: .white) ?? color
        return Color(nsColor: ns)
    }

    /// Static bitmap for the menu bar. Called only when data or the monochrome
    /// setting changes. Monochrome → template image, so macOS tints it like the
    /// system icons (white on dark menu bars, black on light).
    @MainActor
    static func image(color: NSColor, percents: [Double], size: CGFloat, monochrome: Bool) -> NSImage {
        let n = max(percents.count, 1)
        // ring widths that still read at 18 pt: 3 rings → 3.2 pt, 2 rings → 4.5 pt
        let lw = (size / 2 - 1) / (CGFloat(n) + 0.35 * CGFloat(n - 1))
        let view = RingStack(color: color, percents: percents, lineWidth: lw, gap: lw * 0.35, monochrome: monochrome)
            .frame(width: size, height: size)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let img = renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
        img.size = NSSize(width: size, height: size)
        img.isTemplate = monochrome
        return img
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LLMActivity/RingStack.swift
git commit -m "RingStack view and menu bar image renderer"
```

---

### Task 5: Status bar, popover, and app entry point

**Files:**
- Create: `Sources/LLMActivity/StatusBar.swift`
- Create: `Sources/LLMActivity/PopoverView.swift`
- Modify: `Sources/LLMActivity/main.swift` (replace whole file)

**Interfaces:**
- Consumes: `Poller`, `Settings`, `RingStack`, `Provider`, `ProviderUsage`.
- Produces: `@MainActor final class StatusBarController` (`init(poller:settings:)`), `struct PopoverView: View` (`init(poller:settings:)`), `func resetText(_ date: Date?, now: Date) -> String` (also used by the widget in Task 6).

- [ ] **Step 1: Write `PopoverView.swift`**

```swift
import AppKit
import SwiftUI

/// "resets in 42m" / "resets in 3h 12m" / "resets in 6d" / "" when unknown.
func resetText(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let s = max(0, Int(date.timeIntervalSince(now)))
    if s < 3600 { return "resets in \(max(1, s / 60))m" }
    if s < 86400 { return "resets in \(s / 3600)h \((s % 3600) / 60)m" }
    return "resets in \(s / 86400)d"
}

struct PopoverView: View {
    @ObservedObject var poller: Poller
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("llmactivity").font(.system(size: 17, weight: .bold))
            Text(updatedText).font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 6)

            ForEach(poller.usages) { u in
                if u.provider != poller.usages.first?.provider { Divider() }
                ProviderRow(usage: u, now: poller.lastRefresh ?? Date()).padding(.vertical, 10)
            }
            if poller.usages.isEmpty {
                Text("No Claude Code, Codex or Cursor login found on this Mac.")
                    .foregroundStyle(.secondary).padding(.vertical, 12)
            }

            Divider().padding(.bottom, 8)
            Toggle("Monochrome icons", isOn: $settings.monochrome).toggleStyle(.switch).controlSize(.small)
            Toggle("Desktop widget", isOn: $settings.showWidget).toggleStyle(.switch).controlSize(.small)
            HStack(spacing: 8) {
                Button(poller.isRefreshing ? "Refreshing…" : "Refresh") { Task { await poller.refresh() } }
                    .disabled(poller.isRefreshing)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
        }
        .padding(20)
        .frame(width: 360)
    }

    private var updatedText: String {
        guard let t = poller.lastRefresh else { return "Loading…" }
        let s = Int(Date().timeIntervalSince(t))
        return s < 5 ? "Updated just now" : "Updated \(s < 60 ? "\(s)s" : "\(s / 60)m") ago"
    }
}

struct ProviderRow: View {
    let usage: ProviderUsage
    let now: Date

    var body: some View {
        HStack(spacing: 16) {
            RingStack(color: usage.provider.color, percents: usage.limits.map(\.percent), lineWidth: 12, gap: 3)
                .frame(width: 110, height: 110)
                .opacity(usage.isStale ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(usage.provider.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(nsColor: usage.provider.color))
                if let e = usage.error {
                    Text("⚠︎ \(e)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(Array(usage.limits.enumerated()), id: \.offset) { _, l in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(l.label) · \(resetText(l.resetsAt, now: now))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("\(Int(l.percent.rounded()))%")
                            .font(.system(size: 13, weight: .bold)).monospacedDigit()
                    }
                }
                if usage.limits.isEmpty && usage.error == nil {
                    Text("Loading…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Write `StatusBar.swift`**

```swift
import AppKit
import Combine
import SwiftUI

/// One NSStatusItem per installed provider; all of them open the same popover.
@MainActor
final class StatusBarController: NSObject {
    private let poller: Poller
    private let settings: Settings
    private var items: [Provider: NSStatusItem] = [:]
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(poller: Poller, settings: Settings) {
        self.poller = poller
        self.settings = settings
        super.init()

        // Order left→right on the bar = reverse insertion (menu bar grows leftwards).
        for usage in poller.usages.reversed() {
            let item = NSStatusBar.system.statusItem(withLength: 22)
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            item.button?.imagePosition = .imageOnly
            item.button?.toolTip = usage.provider.name
            items[usage.provider] = item
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PopoverView(poller: poller, settings: settings))

        // Re-render the (max three) 18 pt images only when data or the
        // monochrome setting changes. Nothing runs between polls.
        poller.$usages
            .combineLatest(settings.$monochrome)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usages, mono in self?.render(usages, monochrome: mono) }
            .store(in: &cancellables)
    }

    private func render(_ usages: [ProviderUsage], monochrome: Bool) {
        for u in usages {
            guard let button = items[u.provider]?.button else { continue }
            let percents = u.limits.isEmpty ? [0.0] : u.limits.map(\.percent)
            button.image = RingStack.image(color: u.provider.color, percents: percents, size: 18, monochrome: monochrome)
            button.appearsDisabled = u.isStale
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)   // transient popover needs the app active to dismiss on outside click
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
```

- [ ] **Step 3: Replace `main.swift`**

```swift
import AppKit
import Foundation

if CommandLine.arguments.contains("--parsecheck") { exit(runParseCheck()) }
if CommandLine.arguments.contains("--dump") { exit(runDump()) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon

// Keep polling while the Mac is idle (App Nap would otherwise stall the timer).
let activity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep], reason: "Polling AI usage limits")

let settings = Settings.shared
let poller = Poller(providers: Provider.allCases.filter(\.isInstalled))
let statusBar = StatusBarController(poller: poller, settings: settings)
poller.start(interval: settings.pollInterval)

app.run()
```

- [ ] **Step 4: Build, run, and look**

Run: `swift build 2>&1 | grep -E "error|Build complete"; (.build/debug/LLMActivity &) ; sleep 6; screencapture -x /tmp/llmactivity-bar.png; echo captured`
Expected: three ring icons in the menu bar (Claude, Codex, Cursor left→right). Open `/tmp/llmactivity-bar.png` with the Read tool and confirm. Click one icon manually or leave it: the popover cannot be verified from a script; report that it needs a manual click.

Then: `pkill -f .build/debug/LLMActivity`

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "Menu bar icons, popover, app entry point"
```

---

### Task 6: Desktop widget window

**Files:**
- Create: `Sources/LLMActivity/WidgetWindow.swift`
- Modify: `Sources/LLMActivity/main.swift` (add two lines)

**Interfaces:**
- Consumes: `Poller`, `Settings`, `RingStack`, `resetText`.
- Produces: `@MainActor final class WidgetWindow: NSWindow` (`init(poller:settings:)`), shows/hides itself from `settings.$showWidget`.

Read `/Volumes/External/Development/deye-widget/Sources/DeyeWidget/WidgetWindow.swift` first; this is that file reduced to what the spec needs (no scale, no display modes, no pin-to-screen).

- [ ] **Step 1: Write `WidgetWindow.swift`**

```swift
import AppKit
import Combine
import SwiftUI

struct WidgetView: View {
    @ObservedObject var poller: Poller

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            ForEach(poller.usages) { u in
                VStack(spacing: 6) {
                    RingStack(color: u.provider.color, percents: u.limits.map(\.percent), lineWidth: 11, gap: 3)
                        .frame(width: 96, height: 96)
                        .opacity(u.isStale ? 0.5 : 1)
                    Text(u.provider.shortName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(nsColor: u.provider.color))
                    Text(u.limits.map { "\(Int($0.percent.rounded()))%" }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .fixedSize()
    }
}

/// Whole surface is a drag handle. The app is an accessory, so the first click on
/// the inactive window must reach mouseDown for dragging to work.
private final class DragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless translucent card above the wallpaper and under app windows.
/// Position is remembered by the frame autosave name.
@MainActor
final class WidgetWindow: NSWindow {
    private let cornerRadius: CGFloat = 24
    private var cancellables = Set<AnyCancellable>()

    init(poller: Poller, settings: Settings) {
        let hosting = NSHostingView(rootView: WidgetView(poller: poller))
        let size = hosting.fittingSize
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary]

        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.maskImage = Self.roundedMaskImage(radius: cornerRadius)
        visual.wantsLayer = true
        visual.layer?.cornerRadius = cornerRadius
        visual.layer?.cornerCurve = .continuous
        visual.layer?.masksToBounds = true

        hosting.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(hosting)
        let drag = DragView()
        drag.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(drag)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: visual.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            drag.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            drag.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            drag.topAnchor.constraint(equalTo: visual.topAnchor),
            drag.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
        ])
        contentView = visual
        invalidateShadow()

        setFrameAutosaveName("LLMActivityWidget")
        if frame.origin == .zero { center() }

        // Content width changes when a provider's ring count changes; refit.
        poller.$usages
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak hosting] _ in
                guard let self, let hosting else { return }
                let s = hosting.fittingSize
                if s != self.frame.size { self.setContentSize(s) }
            }
            .store(in: &cancellables)

        settings.$showWidget
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                guard let self else { return }
                if show { self.orderFrontRegardless() } else { self.orderOut(nil) }
            }
            .store(in: &cancellables)
    }

    private static func roundedMaskImage(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}
```

- [ ] **Step 2: Add to `main.swift`, after `statusBar`**

```swift
let widget = WidgetWindow(poller: poller, settings: settings)
```

- [ ] **Step 3: Build, run with the widget on, screenshot**

Run: `swift build 2>&1 | grep -E "error|Build complete"; defaults write com.chocksy.llmactivity showWidget -bool true 2>/dev/null; (.build/debug/LLMActivity &); sleep 6; screencapture -x /tmp/llmactivity-widget.png; pkill -f .build/debug/LLMActivity; echo captured`

Note: when run as a bare binary (not an .app bundle) `UserDefaults.standard` uses the binary name as domain; if the `defaults write` above does not take effect, run instead: `defaults write LLMActivity showWidget -bool true`. Open the screenshot with the Read tool: expect a translucent rounded card with three ring stacks on the desktop (it sits under app windows, so it may be hidden by a full-screen terminal; hide other windows or check the screenshot's desktop area).

- [ ] **Step 4: Commit**

```bash
git add Sources
git commit -m "Desktop widget window"
```

---

### Task 7: Packaging, icon, README

**Files:**
- Create: `scripts/make-app.sh`, `scripts/Info.plist.template`, `scripts/make-dmg.sh`, `scripts/make-icon.py`, `.github/workflows/release.yml`
- Create: `assets/icon-1024.png` (generated)
- Create: `README.md`
- Modify: `.gitignore` (whitelist `assets/icon-1024.png` if a rule excludes it; the current file does not)

Read the deye-widget versions of these first: `/Volumes/External/Development/deye-widget/scripts/{make-app.sh,Info.plist.template,make-dmg.sh}` and `/Volumes/External/Development/deye-widget/.github/workflows/release.yml`. Copy them and replace `DeyeWidget` → `LLMActivity`, bundle id → `com.chocksy.llmactivity`, display name → `llmactivity`. Keep `LSUIElement` true.

- [ ] **Step 1: Write `scripts/make-icon.py`** (three ring stacks are too busy at icon size; one 3-ring stack in the Claude coral on a dark squircle)

```python
#!/usr/bin/env python3
"""Generate assets/icon-1024.png: dark rounded square with a 3-ring stack."""
from PIL import Image, ImageDraw

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle((0, 0, S - 1, S - 1), radius=230, fill=(28, 28, 30, 255))

rings = [((232, 132, 92), 0.07), ((242, 176, 148), 0.07), ((250, 214, 196), 0.48)]  # (color, fraction)
lw, gap, r = 88, 26, S / 2 - 120
for i, (col, frac) in enumerate(rings):
    rr = r - i * (lw + gap)
    box = (S / 2 - rr, S / 2 - rr, S / 2 + rr, S / 2 + rr)
    d.ellipse(box, outline=col + (56,), width=lw)
    if frac > 0:
        d.arc(box, start=-90, end=-90 + 360 * frac, fill=col + (255,), width=lw)
        # round caps
        import math
        for ang in (-90, -90 + 360 * frac):
            a = math.radians(ang)
            cx, cy = S / 2 + (rr - lw / 2) * math.cos(a), S / 2 + (rr - lw / 2) * math.sin(a)
            d.ellipse((cx - lw / 2, cy - lw / 2, cx + lw / 2, cy + lw / 2), fill=col + (255,))
img.save("assets/icon-1024.png")
print("wrote assets/icon-1024.png")
```

Run: `mkdir -p assets && python3 scripts/make-icon.py` → `wrote assets/icon-1024.png`. Open it with the Read tool and confirm rings are visible.

- [ ] **Step 2: Copy and adapt the four packaging files from deye-widget** (names swapped as above). `make-app.sh` must `swift build -c release`, assemble `LLMActivity.app`, build the icns from `assets/icon-1024.png`, and ad-hoc codesign, exactly like the deye version.

- [ ] **Step 3: Write `README.md`**

```markdown
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
scripts/make-app.sh 0.1.0                # LLMActivity.app (ad-hoc signed)
scripts/make-dmg.sh 0.1.0
```

Not notarized: on first launch right-click → Open, or `xattr -cr /Applications/LLMActivity.app`.

## Settings

In the popover: **Monochrome icons** (template images, like the system icons) and **Desktop widget**. Poll interval: `defaults write com.chocksy.llmactivity pollInterval 30` (seconds, min 15).

## Known limits

No token refresh: if a tool's token expired, the icon dims and the popover says so; open that tool once.
```

- [ ] **Step 4: Build the app bundle and launch it**

Run: `scripts/make-app.sh 0.1.0 2>&1 | tail -3 && open LLMActivity.app && sleep 5 && screencapture -x /tmp/llmactivity-app.png && echo ok`
Expected: `done: .../LLMActivity.app`; three ring icons in the menu bar. `pgrep -f LLMActivity.app` shows the process. Then `pkill -f LLMActivity.app`.

- [ ] **Step 5: Commit**

```bash
git add scripts assets README.md .github
git commit -m "Packaging, app icon, README, release workflow"
```
