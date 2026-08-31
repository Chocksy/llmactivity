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

    private let settings: Settings
    private let session: URLSession
    private var timer: Timer?
    /// Providers we must not call again before this date (set on HTTP 429).
    private var retryAfter: [Provider: Date] = [:]

    init(providers: [Provider], settings: Settings) {
        usages = providers.map { ProviderUsage(provider: $0) }
        self.settings = settings
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
        // ponytail: fixed 5 min backoff after a 429; honoring the Retry-After header is the upgrade path.
        let now = Date()
        let providers = usages.map(\.provider)
            .filter { settings.isEnabled($0) }
            .filter { (retryAfter[$0].map { $0 <= now }) ?? true }
        guard !providers.isEmpty else { return }   // all backing off: keep the last state and timestamp
        let session = self.session
        // One task per provider. The payload is a struct, not the tuple the plan
        // used: with Swift 6.3.3 in release (-O) the tuple's Provider field came
        // back zeroed, so every result was tagged .claude and the rows got mixed.
        struct Fetched { let provider: Provider; let result: Result<[UsageLimit], Error> }
        let results: [Fetched] = await withTaskGroup(of: Fetched.self) { group in
            for p in providers {
                group.addTask {
                    do { return Fetched(provider: p, result: .success(try await p.fetch(session: session))) }
                    catch { return Fetched(provider: p, result: .failure(error)) }
                }
            }
            var out: [Fetched] = []
            for await r in group { out.append(r) }
            return out
        }
        for f in results {
            let (p, r) = (f.provider, f.result)
            guard let i = usages.firstIndex(where: { $0.provider == p }) else { continue }
            switch r {
            case .success(let limits):
                usages[i].limits = limits
                usages[i].fetchedAt = Date()
                usages[i].error = nil
                retryAfter[p] = nil
            case .failure(let e):
                usages[i].error = (e as? ProviderError)?.description
                    ?? ((e as? URLError) != nil ? "Offline" : e.localizedDescription)
                if case .http(429)? = e as? ProviderError {
                    retryAfter[p] = Date().addingTimeInterval(300)
                }
            }
        }
        lastRefresh = Date()
    }
}
