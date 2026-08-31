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
    /// The provider whose button the popover is anchored to, so hiding *that*
    /// item can close it while hiding any other one leaves it open.
    private var anchorProvider: Provider?

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

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hosting

        // Every installed provider gets its item once, for the life of the app.
        // Order left→right on the bar = reverse insertion (menu bar grows leftwards).
        for usage in poller.usages.reversed() {
            let item = NSStatusBar.system.statusItem(withLength: 22)
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            item.button?.imagePosition = .imageOnly
            item.button?.toolTip = usage.provider.name
            items[usage.provider] = item
        }

        // Re-render the (max three) 18 pt images only when data or the
        // monochrome setting changes. Nothing runs between polls.
        poller.$usages
            .combineLatest(settings.$monochrome)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usages, mono in self?.render(usages, monochrome: mono) }
            .store(in: &cancellables)

        // Hiding a provider only flips its item's visibility, so the popover the
        // checkbox lives in survives the toggle. Emits the current value on
        // subscribe, so this also applies the saved state at launch.
        settings.$disabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] disabled in self?.applyVisibility(disabled) }
            .store(in: &cancellables)
    }

    private func applyVisibility(_ disabled: Set<Provider>) {
        for (provider, item) in items { item.isVisible = !disabled.contains(provider) }
        // The popover has nothing left to hang from once its own item is gone.
        if let anchor = anchorProvider, disabled.contains(anchor) { popover.performClose(nil) }
        render(poller.usages, monochrome: settings.monochrome)
    }

    private func render(_ usages: [ProviderUsage], monochrome: Bool) {
        for u in usages {
            guard let item = items[u.provider], let button = item.button else { continue }
            let percents = u.limits.isEmpty ? [0.0] : u.limits.map(\.percent)
            item.length = 22
            // Monochrome only flips the image to a template, so macOS tints the
            // ring like the system icons instead of keeping the provider color.
            button.image = RingStack.image(colors: u.provider.ringColors, percents: percents, size: 18, monochrome: monochrome)
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.appearsDisabled = u.isStale
        }
    }

    /// `--show-popover`: the same code path as a click on the first visible status item.
    func showPopover() {
        guard let provider = poller.usages.map(\.provider).first(where: { items[$0]?.isVisible == true }),
              let button = items[provider]?.button else { return }
        togglePopover(button)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            anchorProvider = items.first(where: { $0.value.button === sender })?.key
            NSApp.activate(ignoringOtherApps: true)   // transient popover needs the app active to dismiss on outside click
            // Size the popover before it opens, so it hangs below the menu bar
            // instead of growing upward once the content lays out.
            hosting.view.layoutSubtreeIfNeeded()
            popover.contentSize = hosting.view.fittingSize
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
