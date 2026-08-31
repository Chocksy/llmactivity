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
