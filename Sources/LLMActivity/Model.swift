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
