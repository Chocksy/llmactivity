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
        .frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
            RingStack(color: usage.provider.color,
                      percents: usage.limits.isEmpty ? [0.0] : usage.limits.map(\.percent),
                      lineWidth: 12, gap: 3)
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
