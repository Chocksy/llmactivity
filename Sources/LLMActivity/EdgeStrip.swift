import AppKit
import Combine
import SwiftUI

struct EdgeStripView: View {
    @ObservedObject var poller: Poller
    @ObservedObject var settings: Settings
    var hovered: Provider? = nil

    /// Fixed item metrics, so the window can map a mouse y to a tool without asking SwiftUI.
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 8
    static let itemHeight: CGFloat = 64

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(poller.usages.filter { settings.isEnabled($0.provider) }) { u in
                let r = settings.rings(u)
                let on = hovered == u.provider
                VStack(spacing: 4) {
                    RingStack(colors: r.colors, percents: r.percents, lineWidth: 3, gap: 1.2)
                        .frame(width: 42, height: 42)
                        .overlay(
                            Image(systemName: u.provider.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        )
                    Text(worst(u))
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                }
                .frame(width: 52, height: Self.itemHeight)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(on ? 0.12 : 0)))
                .scaleEffect(on ? 1.05 : 1)
                .opacity(u.isStale ? 0.5 : 1)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovered)
        .padding(.vertical, Self.padding)
        .padding(.horizontal, 7)
        .background(
            // Round only the corners away from the screen edge; the other side runs flush into it.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .padding(settings.edgeSide == .right ? .trailing : .leading, -18)
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

/// Rounded card with a small pointer on one side, aimed at the hovered tool.
struct PointerCard: Shape {
    var pointerY: CGFloat        // from the top
    var pointerOnRight: Bool
    static let pointer: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let p = Self.pointer
        let body = pointerOnRight
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width - p, height: rect.height)
            : CGRect(x: rect.minX + p, y: rect.minY, width: rect.width - p, height: rect.height)
        // Keep the pointer clear of the rounded corners.
        let y = rect.minY + min(max(pointerY, 12 + p), rect.height - 12 - p)
        var path = Path(roundedRect: body, cornerRadius: 12, style: .continuous)
        let base = pointerOnRight ? body.maxX : body.minX
        let tip = pointerOnRight ? rect.maxX : rect.minX
        path.move(to: CGPoint(x: base, y: y - p))
        path.addLine(to: CGPoint(x: tip, y: y))
        path.addLine(to: CGPoint(x: base, y: y + p))
        path.closeSubpath()
        return path
    }
}

/// Hover card: the popover's limit rows for one tool, read-only, hidden limits left out.
struct EdgeCardView: View {
    @ObservedObject var poller: Poller
    @ObservedObject var settings: Settings
    let provider: Provider
    var pointerY: CGFloat = 0

    var body: some View {
        // The strip is on the right → the card sits left of it → pointer on the card's right.
        let pointerOnRight = settings.edgeSide == .right
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
        .padding(pointerOnRight ? .trailing : .leading, PointerCard.pointer)
        .background(PointerCard(pointerY: pointerY, pointerOnRight: pointerOnRight).fill(Color.black.opacity(0.92)))
        .environment(\.colorScheme, .dark)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Black strip docked to the left or right edge of a screen. Drag it anywhere, even to
/// another screen; on release it snaps to the nearest side edge of the screen under the mouse.
/// Hovering a tool opens its card in a child window beside it, so the strip itself never moves.
@MainActor
final class EdgeStripWindow: NSWindow {
    private let poller: Poller
    private let settings: Settings
    private let hosting: NSHostingView<EdgeStripView>
    private let card: NSWindow
    private let cardHosting: NSHostingView<EdgeCardView>
    private var cardProvider: Provider?
    private var drag: (mouse: NSPoint, origin: NSPoint, moved: Bool)?
    private var cancellables = Set<AnyCancellable>()
    private let topKey = "edgeStripY"
    private let screenKey = "edgeStripScreen"
    private static let cardGap: CGFloat = 4

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
            .merge(with: settings.$disabled.map { _ in () }, settings.$hiddenLimits.map { _ in () },
                   settings.$edgeSide.map { _ in () })
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

    /// The screen the user last dropped the strip on; the main screen if it is gone.
    private var homeScreen: NSScreen? {
        let id = UserDefaults.standard.integer(forKey: screenKey)
        return NSScreen.screens.first { Self.displayID($0) == id } ?? NSScreen.screens.first
    }

    private static func displayID(_ s: NSScreen) -> Int {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }

    /// Pins the strip to the chosen side of its screen, top at the saved y, clamped to the visible frame.
    private func place(animate: Bool = false) {
        guard let vf = homeScreen?.visibleFrame else { return }
        hosting.rootView = EdgeStripView(poller: poller, settings: settings, hovered: cardProvider)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let saved = UserDefaults.standard.object(forKey: topKey) as? Double
        let t = min(max(saved.map { CGFloat($0) } ?? vf.midY + size.height / 2, vf.minY + size.height), vf.maxY)
        let x = settings.edgeSide == .right ? vf.maxX - size.width : vf.minX
        setFrame(NSRect(x: x, y: t - size.height, width: size.width, height: size.height), display: true, animate: animate)
        if let p = cardProvider { showCard(p) }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            hideCard()
            drag = (NSEvent.mouseLocation, frame.origin, false)
        case .leftMouseDragged:
            guard var d = drag else { return }
            let m = NSEvent.mouseLocation
            d.moved = d.moved || hypot(m.x - d.mouse.x, m.y - d.mouse.y) > 3
            drag = d
            if d.moved { setFrameOrigin(NSPoint(x: d.origin.x + m.x - d.mouse.x, y: d.origin.y + m.y - d.mouse.y)) }
        case .leftMouseUp:
            if let d = drag, d.moved { snap() }
            drag = nil
        default:
            super.sendEvent(event)
        }
    }

    /// Dropped: stick to the nearer side edge of the screen under the mouse.
    private func snap() {
        let m = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? screen else { return }
        UserDefaults.standard.set(Self.displayID(s), forKey: screenKey)
        UserDefaults.standard.set(Double(frame.maxY), forKey: topKey)
        let side: EdgeSide = m.x < s.frame.midX ? .left : .right
        if settings.edgeSide != side { settings.edgeSide = side }   // the sink re-places too
        place(animate: true)
    }

    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) { hideCard() }

    /// Items have fixed heights, so the row under the mouse is plain arithmetic.
    /// The gap between items counts toward the nearer one, so the card never blinks off in between.
    private func hover(_ event: NSEvent) {
        guard drag == nil else { return }
        let tools = poller.usages.filter { settings.isEnabled($0.provider) }.map(\.provider)
        let y = frame.height - event.locationInWindow.y - EdgeStripView.padding + EdgeStripView.spacing / 2
        let i = Int(floor(y / (EdgeStripView.itemHeight + EdgeStripView.spacing)))
        guard tools.indices.contains(i) else { return hideCard() }
        if tools[i] != cardProvider { showCard(tools[i]) }
    }

    private func showCard(_ p: Provider) {
        let tools = poller.usages.filter { settings.isEnabled($0.provider) }.map(\.provider)
        guard let i = tools.firstIndex(of: p), let vf = screen?.visibleFrame ?? homeScreen?.visibleFrame
        else { return hideCard() }
        let wasHidden = card.parent == nil
        cardProvider = p
        hosting.rootView = EdgeStripView(poller: poller, settings: settings, hovered: p)

        cardHosting.rootView = EdgeCardView(poller: poller, settings: settings, provider: p)
        cardHosting.layoutSubtreeIfNeeded()
        let size = cardHosting.fittingSize
        let mid = frame.maxY - EdgeStripView.padding - CGFloat(i) * (EdgeStripView.itemHeight + EdgeStripView.spacing)
            - EdgeStripView.itemHeight / 2
        let y = min(max(mid - size.height / 2, vf.minY), vf.maxY - size.height)
        // Pointer y measured from the card's top; the height does not depend on it.
        cardHosting.rootView = EdgeCardView(poller: poller, settings: settings, provider: p, pointerY: y + size.height - mid)
        let onRight = settings.edgeSide == .right
        let x = onRight ? frame.minX - Self.cardGap - size.width : frame.maxX + Self.cardGap
        let target = NSRect(x: x, y: y, width: size.width, height: size.height)

        if wasHidden {
            // Fade in while sliding 10 pt out of the strip.
            card.setFrame(target.offsetBy(dx: onRight ? 10 : -10, dy: 0), display: true)
            card.alphaValue = 0
            addChildWindow(card, ordered: .above)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                card.animator().setFrame(target, display: true)
                card.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                card.animator().setFrame(target, display: true)
            }
        }
    }

    private func hideCard() {
        guard cardProvider != nil || card.parent != nil else { return }
        cardProvider = nil
        hosting.rootView = EdgeStripView(poller: poller, settings: settings, hovered: nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            card.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A new hover may have reopened the card while it faded.
            MainActor.assumeIsolated {
                guard let self, self.cardProvider == nil else { return }
                if self.card.parent != nil { self.removeChildWindow(self.card) }
                self.card.orderOut(nil)
            }
        })
    }
}
