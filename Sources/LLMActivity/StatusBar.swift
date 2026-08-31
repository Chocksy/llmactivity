import AppKit
import Combine
import SwiftUI

/// One NSStatusItem per installed provider; all of them open the same popover.
@MainActor
final class StatusBarController: NSObject {
    private let poller: Poller
    private let settings: Settings
    private var items: [Provider: NSStatusItem] = [:]
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(poller: Poller, settings: Settings) {
        self.poller = poller
        self.settings = settings
        super.init()

        // Order left→right on the bar = reverse insertion (menu bar grows leftwards).
        for usage in poller.usages.reversed() {
            let item = NSStatusBar.system.statusItem(withLength: 22)
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            item.button?.imagePosition = .imageOnly
            item.button?.toolTip = usage.provider.name
            items[usage.provider] = item
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PopoverView(poller: poller, settings: settings))

        // Re-render the (max three) 18 pt images only when data or the
        // monochrome setting changes. Nothing runs between polls.
        poller.$usages
            .combineLatest(settings.$monochrome)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usages, mono in self?.render(usages, monochrome: mono) }
            .store(in: &cancellables)
    }

    private func render(_ usages: [ProviderUsage], monochrome: Bool) {
        for u in usages {
            guard let button = items[u.provider]?.button else { continue }
            let percents = u.limits.isEmpty ? [0.0] : u.limits.map(\.percent)
            button.image = RingStack.image(color: u.provider.color, percents: percents, size: 18, monochrome: monochrome)
            button.appearsDisabled = u.isStale
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)   // transient popover needs the app active to dismiss on outside click
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
