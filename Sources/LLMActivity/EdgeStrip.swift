import AppKit
import Combine
import SwiftUI

struct EdgeStripView: View {
    @ObservedObject var poller: Poller
    @ObservedObject var settings: Settings

    /// Fixed item metrics, so the window can map a mouse y to a tool without asking SwiftUI.
    static let padding: CGFloat = 12
    static let spacing: CGFloat = 12
    static let itemHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(poller.usages.filter { settings.isEnabled($0.provider) }) { u in
                let r = settings.rings(u)
                VStack(spacing: 4) {
                    RingStack(colors: r.colors, percents: r.percents, lineWidth: 3.2, gap: 1.2)
                        .frame(width: 38, height: 38)
                    Text(worst(u))
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: Self.itemHeight)
                .opacity(u.isStale ? 0.5 : 1)
            }
        }
        .padding(.vertical, Self.padding)
        .padding(.horizontal, 10)
        .background(
            // Left corners round, right side runs flush into the screen edge.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .padding(.trailing, -18)
        )
        .clipped()
        .fixedSize()
    }

    private func worst(_ u: ProviderUsage) -> String {
        let shown = u.limits.filter { settings.isShown(u.provider, $0) }
        guard let m = shown.map(\.percent).max() else { return "–" }
        return "\(Int(m.rounded()))%"
    }
}

/// Hover card: the popover's limit rows for one tool, read-only, hidden limits left out.
struct EdgeCardView: View {
    @ObservedObject var poller: Poller
    @ObservedObject var settings: Settings
    let provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: provider.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: provider.color))
                Text(provider.name).font(.system(size: 13, weight: .bold))
            }
            if let u = poller.usages.first(where: { $0.provider == provider }) {
                if let e = u.error {
                    Text("⚠︎ \(e)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(Array(u.limits.enumerated()), id: \.offset) { i, l in
                    if settings.isShown(provider, l) {
                        LimitRow(limit: l, tone: RingStack.warnColor(provider.ringColor(i), percent: l.percent),
                                 shown: true, now: poller.lastRefresh ?? Date())
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.92)))
        .environment(\.colorScheme, .dark)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Black strip docked flush to the right edge of the main screen. Drags only vertically.
/// Hovering a tool opens its card in a child window to the left, so the strip itself never moves.
@MainActor
final class EdgeStripWindow: NSWindow {
    private let poller: Poller
    private let settings: Settings
    private let hosting: NSHostingView<EdgeStripView>
    private let card: NSWindow
    private let cardHosting: NSHostingView<EdgeCardView>
    private var cardProvider: Provider?
    private var dragStart: (mouseY: CGFloat, top: CGFloat)?
    private var cancellables = Set<AnyCancellable>()
    private let topKey = "edgeStripY"

    init(poller: Poller, settings: Settings) {
        self.poller = poller
        self.settings = settings
        hosting = NSHostingView(rootView: EdgeStripView(poller: poller, settings: settings))
        cardHosting = NSHostingView(rootView: EdgeCardView(poller: poller, settings: settings, provider: .claude))
        card = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        super.init(contentRect: NSRect(origin: .zero, size: hosting.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)

        for w in [self, card] {
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.isReleasedWhenClosed = false
            // Above app windows, unlike the card: a strip hidden behind a maximized window is useless.
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.appearance = NSAppearance(named: .darkAqua)
        }
        card.ignoresMouseEvents = true
        card.contentView = cardHosting
        contentView = hosting

        // Tracking area owned by the window: fires even though this accessory app is never active.
        hosting.addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                               owner: self, userInfo: nil))

        poller.$usages.map { _ in () }
            .merge(with: settings.$disabled.map { _ in () }, settings.$hiddenLimits.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.place() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.place() }
            .store(in: &cancellables)

        settings.$showWidget
            .combineLatest(settings.$widgetStyle)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show, style in
                guard let self else { return }
                if show && style == .edge {
                    self.place()
                    self.orderFrontRegardless()
                } else {
                    self.hideCard()
                    self.orderOut(nil)
                }
            }
            .store(in: &cancellables)
    }

    /// Pins the right edge to the screen edge and the top to the saved y, clamped to the visible frame.
    private func place(top: CGFloat? = nil) {
        guard let vf = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let saved = UserDefaults.standard.object(forKey: topKey) as? Double
        let t = min(max(top ?? saved.map { CGFloat($0) } ?? vf.midY + size.height / 2, vf.minY + size.height), vf.maxY)
        setFrame(NSRect(x: vf.maxX - size.width, y: t - size.height, width: size.width, height: size.height), display: true)
        if let p = cardProvider { showCard(p) }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            hideCard()
            dragStart = (NSEvent.mouseLocation.y, frame.maxY)
        case .leftMouseDragged:
            guard let s = dragStart else { return }
            place(top: s.top + NSEvent.mouseLocation.y - s.mouseY)
        case .leftMouseUp:
            if dragStart != nil { UserDefaults.standard.set(Double(frame.maxY), forKey: topKey) }
            dragStart = nil
        default:
            super.sendEvent(event)
        }
    }

    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) { hideCard() }

    /// Items have fixed heights, so the row under the mouse is plain arithmetic.
    /// The gap between items counts toward the nearer one, so the card never blinks off in between.
    private func hover(_ event: NSEvent) {
        guard dragStart == nil else { return }
        let tools = poller.usages.filter { settings.isEnabled($0.provider) }.map(\.provider)
        let y = frame.height - event.locationInWindow.y - EdgeStripView.padding + EdgeStripView.spacing / 2
        let i = Int(floor(y / (EdgeStripView.itemHeight + EdgeStripView.spacing)))
        guard tools.indices.contains(i) else { return hideCard() }
        if tools[i] != cardProvider { showCard(tools[i]) }
    }

    private func showCard(_ p: Provider) {
        let tools = poller.usages.filter { settings.isEnabled($0.provider) }.map(\.provider)
        guard let i = tools.firstIndex(of: p), let vf = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        else { return hideCard() }
        cardProvider = p
        cardHosting.rootView = EdgeCardView(poller: poller, settings: settings, provider: p)
        cardHosting.layoutSubtreeIfNeeded()
        let size = cardHosting.fittingSize
        let mid = frame.maxY - EdgeStripView.padding - CGFloat(i) * (EdgeStripView.itemHeight + EdgeStripView.spacing)
            - EdgeStripView.itemHeight / 2
        let y = min(max(mid - size.height / 2, vf.minY), vf.maxY - size.height)
        card.setFrame(NSRect(x: frame.minX - 8 - size.width, y: y, width: size.width, height: size.height), display: true)
        if card.parent == nil { addChildWindow(card, ordered: .above) }
    }

    private func hideCard() {
        cardProvider = nil
        if card.parent != nil { removeChildWindow(card) }
        card.orderOut(nil)
    }
}
