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
    private let hosting: NSHostingController<PopoverView>
    private var cancellables = Set<AnyCancellable>()

    init(poller: Poller, settings: Settings) {
        self.poller = poller
        self.settings = settings
        // .preferredContentSize makes the hosting controller report the SwiftUI
        // intrinsic size to the popover. Without it the popover opens at a
        // default size and grows upward past the top of the screen when the
        // rows load, clipping the header.
        self.hosting = NSHostingController(rootView: PopoverView(poller: poller, settings: settings))
        hosting.sizingOptions = [.preferredContentSize]
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
        popover.contentViewController = hosting

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
            guard let item = items[u.provider], let button = item.button else { continue }
            let percents = u.limits.isEmpty ? [0.0] : u.limits.map(\.percent)
            // Monochrome rings all look alike, so stack the tool name over a smaller ring.
            if monochrome {
                item.length = NSStatusItem.variableLength
                button.image = RingStack.stackedImage(color: u.provider.color, percents: percents,
                                                      label: u.provider.shortName, monochrome: true)
            } else {
                item.length = 22
                button.image = RingStack.image(color: u.provider.color, percents: percents, size: 18, monochrome: false)
            }
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.appearsDisabled = u.isStale
        }
    }

    /// `--show-popover`: the same code path as a click on the first status item.
    func showPopover() {
        guard let provider = poller.usages.first?.provider, let button = items[provider]?.button else { return }
        togglePopover(button)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)   // transient popover needs the app active to dismiss on outside click
            // Size the popover before it opens, so it hangs below the menu bar
            // instead of growing upward once the content lays out.
            hosting.view.layoutSubtreeIfNeeded()
            popover.contentSize = hosting.view.fittingSize
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
