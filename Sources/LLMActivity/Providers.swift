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

    /// One tone per ring, outer→inner, inside the tool's brand family.
    /// The legend dot next to each limit uses the same entry.
    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "terminal"
        case .cursor: return "cube.fill"
        }
    }

    var ringColors: [NSColor] {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch self {
        case .claude: return [c(0xE8845C), c(0xECC06F), c(0xF7E2C0)]
        case .codex: return [c(0x34D399), c(0xB8E986)]
        case .cursor: return [c(0xA78BFA), c(0x7DC4FA)]
        }
    }
    /// Tone of limit i; extra limits reuse the innermost tone.
    func ringColor(_ i: Int) -> NSColor { i < ringColors.count ? ringColors[i] : ringColors.last ?? color }

    /// "Installed" = the tool left credentials on this Mac.
    var isInstalled: Bool {
        switch self {
        case .claude: return ClaudeAuth.rawJSON() != nil
        case .codex: return FileManager.default.fileExists(atPath: CodexAuth.path)
        case .cursor: return CursorAuth.keychainToken() != nil || FileManager.default.fileExists(atPath: CursorAuth.dbPath)
        }
    }

    /// Anthropic's usage endpoint 429s after a few calls per minute; hold Claude to one call per 5 min.
    var minPollInterval: TimeInterval {
        switch self {
        case .claude: return 300
        case .codex, .cursor: return 60
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
            // cursor.com/api/usage-summary still answers, but with a stale monthly 0% on the
            // weekly "Super" plans; the dashboard RPC has the live numbers.
            let token = try CursorAuth.accessToken()
            req = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
            req.httpMethod = "POST"
            req.httpBody = Data("{}".utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("llmactivity", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 429 {
            let secs = http?.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Int($0) }.flatMap { $0 > 0 ? TimeInterval($0) : nil }
            throw ProviderError.rateLimited(retryAfter: secs)
        }
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

    /// Rings outer→inner: session (5h), weekly_scoped (model name), weekly_all.
    /// Fast window outside like a clock second hand; slower budgets toward the center.
    static func parseClaude(_ data: Data) throws -> [UsageLimit] {
        let root = try json(data)
        guard let limits = root["limits"] as? [[String: Any]] else { throw ProviderError.unexpected("no limits[]") }
        func find(_ kind: String) -> [String: Any]? { limits.first { $0["kind"] as? String == kind } }
        func pct(_ l: [String: Any]) -> Double { (l["percent"] as? Double) ?? 0 }
        var out: [UsageLimit] = []
        if let l = find("session") {
            out.append(UsageLimit(key: "session", label: "5h session", percent: pct(l), resetsAt: DateParse.iso(l["resets_at"])))
        }
        if let l = find("weekly_scoped") {
            let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String ?? "Model"
            out.append(UsageLimit(key: "weekly_scoped", label: "\(model) weekly", percent: pct(l), resetsAt: DateParse.iso(l["resets_at"])))
        }
        if let l = find("weekly_all") {
            out.append(UsageLimit(key: "weekly_all", label: "Weekly", percent: pct(l), resetsAt: DateParse.iso(l["resets_at"])))
        }
        guard !out.isEmpty else { throw ProviderError.unexpected("no known limit kinds") }
        return out
    }

    /// Rings outer→inner: primary_window (5h), secondary_window (weekly).
    /// Fast window outside, slow budget inside — same clock order as Claude.
    static func parseCodex(_ data: Data) throws -> [UsageLimit] {
        let root = try json(data)
        guard let rl = root["rate_limit"] as? [String: Any] else { throw ProviderError.unexpected("no rate_limit") }
        var out: [UsageLimit] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = rl[key] as? [String: Any] else { continue }
            let secs = (w["limit_window_seconds"] as? Double) ?? 0
            let label = secs >= 6 * 86400 ? "Weekly" : "\(max(1, Int(secs / 3600)))h session"
            out.append(UsageLimit(key: key, label: label, percent: (w["used_percent"] as? Double) ?? 0, resetsAt: DateParse.unix(w["reset_at"])))
        }
        guard !out.isEmpty else { throw ProviderError.unexpected("no rate windows") }
        return out
    }

    /// Rings outer→inner: API models, Auto. Both reset at billingCycleEnd.
    /// Weekly "Super" plans have one pool (totalPercentUsed). Older plans split it into
    /// API models + Auto; show both rings when apiPercentUsed is present.
    static func parseCursor(_ data: Data) throws -> [UsageLimit] {
        let root = try json(data)
        guard let plan = root["planUsage"] as? [String: Any] else {
            throw ProviderError.unexpected("no planUsage")
        }
        func ms(_ any: Any?) -> Double? { (any as? String).flatMap(Double.init) ?? (any as? Double) }
        let start = ms(root["billingCycleStart"]), endMs = ms(root["billingCycleEnd"])
        let end = endMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        if let api = plan["apiPercentUsed"] as? Double {
            return [
                UsageLimit(key: "api", label: "API models", percent: api, resetsAt: end),
                UsageLimit(key: "auto", label: "Auto", percent: (plan["autoPercentUsed"] as? Double) ?? 0, resetsAt: end),
            ]
        }
        guard let total = plan["totalPercentUsed"] as? Double else { throw ProviderError.unexpected("no totalPercentUsed") }
        let days = (start.flatMap { s in endMs.map { ($0 - s) / 86_400_000 } }) ?? 0
        return [UsageLimit(key: "total", label: days > 0 && days < 8 ? "Weekly" : "Monthly", percent: total, resetsAt: end)]
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

    /// The cursor-agent CLI keeps a JWT in the Keychain; the IDE's state DB now holds an
    /// opaque `cursor-…` token the API rejects (seen after the ChatGPT-login switch).
    /// Prefer the Keychain JWT, fall back to the DB for IDE-only installs.
    static func accessToken() throws -> String {
        if let t = keychainToken() { return t }
        if let t = try? query(immutable: false) { return t }
        return try query(immutable: true)
    }

    /// Via /usr/bin/security for the same reason as ClaudeAuth.
    static func keychainToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "cursor-access-token", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let t = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
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
