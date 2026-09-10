import AppKit
import Combine
import Foundation

/// Checks GitHub releases for a newer tag and offers a link to the DMG.
/// ponytail: notify-and-open-browser, no self-installing updater. Ad-hoc signed
/// builds can't be verified after download, so Sparkle/EdDSA is the upgrade path
/// if unattended installs ever matter.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Newer version tag, nil when up to date or the check failed.
    @Published private(set) var available: String?

    private let api = URL(string: "https://api.github.com/repos/Chocksy/llmactivity/releases/latest")!
    private let page = URL(string: "https://github.com/Chocksy/llmactivity/releases/latest")!
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        timer?.tolerance = 3600
        Task { await check() }
    }

    func check() async {
        guard let (data, _) = try? await URLSession.shared.data(from: api),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else { return }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        available = Self.isNewer(latest, than: Self.currentVersion) ? latest : nil
    }

    /// .numeric compares digit runs as numbers, so 0.10.0 > 0.9.0.
    nonisolated static func isNewer(_ latest: String, than current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }

    func openReleasePage() { NSWorkspace.shared.open(page) }
}
