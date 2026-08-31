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
