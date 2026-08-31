import AppKit
import Foundation

if CommandLine.arguments.contains("--parsecheck") { exit(runParseCheck()) }
if CommandLine.arguments.contains("--dump") { exit(runDump()) }

// Same shape as deye-widget's entry point: the whole GUI setup runs on the main
// actor (top-level code is nonisolated, so the @MainActor types need this).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon

    // Keep polling while the Mac is idle (App Nap would otherwise stall the timer).
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep], reason: "Polling AI usage limits")

    let settings = Settings.shared
    let poller = Poller(providers: Provider.allCases.filter(\.isInstalled))
    let statusBar = StatusBarController(poller: poller, settings: settings)
    let widget = WidgetWindow(poller: poller, settings: settings)
    poller.start(interval: settings.pollInterval)

    withExtendedLifetime((activity, statusBar, widget)) {
        app.run()
    }
}
