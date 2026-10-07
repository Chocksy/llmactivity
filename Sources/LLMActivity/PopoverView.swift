import AppKit
import SwiftUI

/// "Resets in 42m" / "Resets in 3h 12m" / "Resets Thu 10:32" / "Resets Oct 22" / "" when unknown.
/// Past a day the weekday and clock time say more than "in 4d"; past 6 days a weekday is ambiguous.
func resetText(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let s = max(0, Int(date.timeIntervalSince(now)))
    if s < 3600 { return "Resets in \(max(1, s / 60))m" }
    if s < 86400 { return "Resets in \(s / 3600)h \((s % 3600) / 60)m" }
    if s < 6 * 86400 { return "Resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
    return "Resets " + date.formatted(.dateTime.month(.abbreviated).day())
}

struct PopoverView: View {
    @ObservedObject var poller: Poller
    @ObservedObject var settings: Settings
    @ObservedObject var updater = Updater.shared
    @State var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingSettings { settingsView } else { usageView }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { showingSettings = false }
    }

    @ViewBuilder
    private var usageView: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text("llmactivity").font(.system(size: 17, weight: .bold))
                Text(updatedText).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await poller.refresh(force: true) } }
                .disabled(poller.isRefreshing)
                .opacity(poller.isRefreshing ? 0.4 : 1)
            IconButton(symbol: "gearshape", help: "Settings") { showingSettings = true }
        }
        .padding(.bottom, 4)

        ForEach(rows) { u in
            ProviderCard(usage: u, settings: settings, now: poller.lastRefresh ?? Date()).padding(.top, 8)
        }
        if poller.usages.isEmpty {
            Text("No Claude Code, Codex or Cursor login found on this Mac.")
                .foregroundStyle(.secondary).padding(.vertical, 12)
        } else if rows.isEmpty {
            Text("All tools hidden. Enable one in Settings.")
                .foregroundStyle(.secondary).padding(.vertical, 12)
        }

        if let v = updater.available {
            Button(updater.installing ? "Installing v\(v)…" : "Update to v\(v)") { updater.install() }
                .disabled(updater.installing)
                .buttonStyle(.link)
                .font(.system(size: 12))
                .padding(.top, 10)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var settingsView: some View {
        Button { showingSettings = false } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                Text("Settings").font(.system(size: 15, weight: .bold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)

        ForEach(poller.usages) { u in
            let on = settings.isEnabled(u.provider)
            sectionHeader(u.provider.name.uppercased())
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Show \(u.provider.name)", isOn: Binding(
                    get: { on },
                    set: { settings.setEnabled(u.provider, $0) }))
                ForEach(u.limits, id: \.key) { l in
                    Toggle(l.label, isOn: Binding(
                        get: { settings.isShown(u.provider, l) },
                        set: { if $0 != settings.isShown(u.provider, l) { settings.toggleShown(u.provider, l) } }))
                        .padding(.leading, 20)
                        .disabled(!on)
                }
                if u.limits.isEmpty {
                    Text(u.error ?? "Loading…").font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 13))
        }

        sectionHeader("OPTIONS")
        VStack(spacing: 8) {
            optionRow("Monochrome icons", isOn: $settings.monochrome)
            optionRow("Desktop widget", isOn: $settings.showWidget)
            if settings.showWidget {
                HStack {
                    Text("Style").font(.system(size: 13))
                    Spacer()
                    Picker("Style", selection: $settings.widgetStyle) {
                        Text("Card").tag(WidgetStyle.card)
                        Text("Edge strip").tag(WidgetStyle.edge)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize()
                }
                if settings.widgetStyle == .edge {
                    HStack {
                        Text("Side").font(.system(size: 13))
                        Spacer()
                        Picker("Side", selection: $settings.edgeSide) {
                            Text("Left").tag(EdgeSide.left)
                            Text("Right").tag(EdgeSide.right)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
            }
        }

        Button("Quit") { NSApp.terminate(nil) }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 14)
    }

    /// Small all-caps label that groups the settings.
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    /// Label left, switch flush right, so the switches line up in one column.
    @ViewBuilder
    private func optionRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    /// Installed providers the user has not hidden, in the fixed order.
    private var rows: [ProviderUsage] { poller.usages.filter { settings.isEnabled($0.provider) } }

    private var updatedText: String {
        guard let t = poller.lastRefresh else { return "Loading…" }
        let s = Int(Date().timeIntervalSince(t))
        return s < 5 ? "Updated just now" : "Updated \(s < 60 ? "\(s)s" : "\(s / 60)m") ago"
    }
}

/// Small borderless symbol button with a round hover highlight.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct ProviderCard: View {
    let usage: ProviderUsage
    @ObservedObject var settings: Settings
    let now: Date

    var body: some View {
        let rings = settings.rings(usage)
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RingStack(colors: rings.colors, percents: rings.percents, lineWidth: 6, gap: 2)
                Image(systemName: usage.provider.symbol)
                    .font(.system(size: rings.percents.count > 2 ? 10 : 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: usage.provider.color))
            }
            .frame(width: 56, height: 56)
            .opacity(usage.isStale ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 8) {
                Text(usage.provider.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(nsColor: usage.provider.color))
                if let e = usage.error {
                    Text("⚠︎ \(e)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(Array(usage.limits.enumerated()), id: \.offset) { i, l in
                    LimitRow(limit: l, tone: RingStack.warnColor(usage.provider.ringColor(i), percent: l.percent),
                             shown: settings.isShown(usage.provider, l), now: now) {
                        settings.toggleShown(usage.provider, l)
                    }
                }
                if usage.limits.isEmpty && usage.error == nil {
                    Text("Loading…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// One limit: dot, label, percent, then a bar and the reset time.
/// With `toggle` the row doubles as the show/hide switch: click it to drop its ring.
/// A hidden row stays, dimmed with a hollow dot and no bar, so it can come back.
struct LimitRow: View {
    let limit: UsageLimit
    let tone: NSColor
    let shown: Bool
    let now: Date
    var toggle: (() -> Void)? = nil

    var body: some View {
        if let toggle {
            Button(action: toggle) { content }
                .buttonStyle(.plain)
                .help(shown ? "Hide this limit from the rings" : "Show this limit in the rings")
        } else {
            content
        }
    }

    private var content: some View {
        let c = Color(nsColor: tone)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .strokeBorder(c, lineWidth: 1.5)
                    .background(Circle().fill(shown ? c : .clear))
                    .frame(width: 9, height: 9)
                    .alignmentGuide(.firstTextBaseline) { $0.height - 1 }
                Text(limit.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.system(size: 13, weight: .bold)).monospacedDigit()
                    .foregroundStyle(limit.percent >= 60 ? c : .primary)
            }
            VStack(alignment: .leading, spacing: 3) {
                if shown {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.12))
                            Capsule().fill(c)
                                .frame(width: g.size.width * max(min(limit.percent, 100), 1.5) / 100)
                        }
                    }
                    .frame(height: 4)
                }
                Text(shown ? resetText(limit.resetsAt, now: now) : "Hidden, click to show")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.leading, 16)
        }
        .contentShape(Rectangle())
        .opacity(shown ? 1 : 0.4)
    }
}
