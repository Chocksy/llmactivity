import AppKit
import Combine
import Foundation

/// Checks GitHub releases daily. A newer release installs by itself: download the
/// DMG, require our Developer ID signature, swap the bundle after we quit, relaunch.
/// ponytail: no Sparkle; the team-ID check stands in for its EdDSA feed signature.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Newer version tag, nil when up to date or the check failed.
    @Published private(set) var available: String?
    @Published private(set) var installing = false
    private var dmg: URL?

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
        dmg = (root["assets"] as? [[String: Any]])?
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:))
        if available != nil { install(auto: true) }
    }

    /// Auto installs fail quietly (the popover button stays); a click falls back to the release page.
    func install(auto: Bool = false) {
        guard !installing else { return }
        guard let dmg else { if !auto { openReleasePage() }; return }
        installing = true
        let target = Bundle.main.bundlePath
        Task {
            do {
                try await Self.stage(dmg, over: target)
                NSApp.terminate(nil)
            } catch {
                NSLog("LLMActivity update failed: \(error)")
                installing = false
                if !auto { openReleasePage() }
            }
        }
    }

    struct Failure: Error { let what: String }
    nonisolated static let teamID = "9SRWEPF965"

    /// Leaves a verified copy of the new app next to a helper that swaps it in once this process exits.
    nonisolated static func stage(_ url: URL, over target: String) async throws {
        let fm = FileManager.default
        guard target.hasSuffix(".app"),
              fm.isWritableFile(atPath: (target as NSString).deletingLastPathComponent)
        else { throw Failure(what: "not running from a writable .app") }

        let work = fm.temporaryDirectory.appendingPathComponent("llmactivity-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let (tmp, _) = try await URLSession.shared.download(from: url)
        let image = work.appendingPathComponent("update.dmg")
        try fm.moveItem(at: tmp, to: image)

        let mount = work.appendingPathComponent("mnt").path
        try run("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount, image.path)
        defer { _ = try? run("/usr/bin/hdiutil", "detach", "-force", mount) }
        let fresh = work.appendingPathComponent("LLMActivity.app").path
        try run("/usr/bin/ditto", mount + "/LLMActivity.app", fresh)
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict",
                "-R=anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"", fresh)

        // Wait for us to exit, swap (restore the old app if the move fails), relaunch.
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            mv "$2" "$4/old.app" && { mv "$3" "$2" || mv "$4/old.app" "$2"; }
            open "$2"
            """, "sh", "\(ProcessInfo.processInfo.processIdentifier)", target, fresh, work.path]
        try swap.run()
    }

    nonisolated static func run(_ tool: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(what: "\(tool) exited \(p.terminationStatus)") }
    }

    /// .numeric compares digit runs as numbers, so 0.10.0 > 0.9.0.
    nonisolated static func isNewer(_ latest: String, than current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }

    func openReleasePage() { NSWorkspace.shared.open(page) }
}
