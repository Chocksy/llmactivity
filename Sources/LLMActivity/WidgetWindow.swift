import AppKit
import Combine
import SwiftUI

struct WidgetView: View {
    @ObservedObject var poller: Poller

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            ForEach(poller.usages) { u in
                VStack(spacing: 6) {
                    RingStack(color: u.provider.color,
                              percents: u.limits.isEmpty ? [0.0] : u.limits.map(\.percent),
                              lineWidth: 11, gap: 3)
                        .frame(width: 96, height: 96)
                        .opacity(u.isStale ? 0.5 : 1)
                    Text(u.provider.shortName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(nsColor: u.provider.color))
                    Text(u.limits.map { "\(Int($0.percent.rounded()))%" }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .fixedSize()
    }
}

/// Whole surface is a drag handle. The app is an accessory, so the first click on
/// the inactive window must reach mouseDown for dragging to work.
private final class DragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless translucent card above the wallpaper and under app windows.
/// Position is remembered by the frame autosave name.
@MainActor
final class WidgetWindow: NSWindow {
    private let cornerRadius: CGFloat = 24
    private var cancellables = Set<AnyCancellable>()

    init(poller: Poller, settings: Settings) {
        let hosting = NSHostingView(rootView: WidgetView(poller: poller))
        let size = hosting.fittingSize
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary]

        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.maskImage = Self.roundedMaskImage(radius: cornerRadius)
        visual.wantsLayer = true
        visual.layer?.cornerRadius = cornerRadius
        visual.layer?.cornerCurve = .continuous
        visual.layer?.masksToBounds = true

        hosting.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(hosting)
        let drag = DragView()
        drag.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(drag)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: visual.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            drag.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            drag.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            drag.topAnchor.constraint(equalTo: visual.topAnchor),
            drag.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
        ])
        contentView = visual
        invalidateShadow()

        setFrameAutosaveName("LLMActivityWidget")
        if frame.origin == .zero { center() }

        // Content width changes when a provider's ring count changes; refit.
        poller.$usages
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak hosting] _ in
                guard let self, let hosting else { return }
                let s = hosting.fittingSize
                if s != self.frame.size { self.setContentSize(s) }
            }
            .store(in: &cancellables)

        settings.$showWidget
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                guard let self else { return }
                if show { self.orderFrontRegardless() } else { self.orderOut(nil) }
            }
            .store(in: &cancellables)
    }

    private static func roundedMaskImage(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}
