import AppKit
import Combine
import ServiceManagement

enum WidgetStyle: String { case card, edge }
enum EdgeSide: String { case left, right }

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var monochrome: Bool { didSet { d.set(monochrome, forKey: "monochrome") } }
    @Published var showWidget: Bool { didSet { d.set(showWidget, forKey: "showWidget") } }
    @Published var widgetStyle: WidgetStyle { didSet { d.set(widgetStyle.rawValue, forKey: "widgetStyle") } }
    @Published var edgeSide: EdgeSide { didSet { d.set(edgeSide.rawValue, forKey: "edgeSide") } }
    /// Providers the user hid, so the menu bar does not get crowded.
    @Published var disabled: Set<Provider> { didSet { d.set(disabled.map(\.rawValue), forKey: "disabledProviders") } }

    /// Single limits the user hid ("claude.weekly_scoped"), e.g. a model they stopped using.
    /// Backed by the system login items list, so it stays right if the user changes it in System Settings.
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login: \(error)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    @Published var hiddenLimits: Set<String> { didSet { d.set(Array(hiddenLimits), forKey: "hiddenLimits") } }
    /// Provider → limit key whose percent the edge strip shows. Missing = the highest shown limit.
    @Published var stripLimit: [String: String] { didSet { d.set(stripLimit, forKey: "stripLimit") } }

    /// The number under a tool in the edge strip: the picked limit if still shown, else the highest shown one.
    func stripPercent(_ u: ProviderUsage) -> Double? {
        let shown = u.limits.filter { isShown(u.provider, $0) }
        if let k = stripLimit[u.provider.rawValue], let l = shown.first(where: { $0.key == k }) { return l.percent }
        return shown.map(\.percent).max()
    }

    func isEnabled(_ p: Provider) -> Bool { !disabled.contains(p) }
    func setEnabled(_ p: Provider, _ on: Bool) {
        if on { disabled.remove(p) } else { disabled.insert(p) }
    }

    func isShown(_ p: Provider, _ l: UsageLimit) -> Bool { !hiddenLimits.contains("\(p.rawValue).\(l.key)") }
    func toggleShown(_ p: Provider, _ l: UsageLimit) {
        let k = "\(p.rawValue).\(l.key)"
        if hiddenLimits.contains(k) { hiddenLimits.remove(k) } else { hiddenLimits.insert(k) }
    }

    /// Rings for the limits still shown. Each keeps the tone of its original slot,
    /// so hiding the middle ring does not repaint the inner one.
    func rings(_ u: ProviderUsage) -> (colors: [NSColor], percents: [Double]) {
        let shown = u.limits.indices.filter { isShown(u.provider, u.limits[$0]) }
        if shown.isEmpty { return ([u.provider.ringColor(0)], [0]) }
        return (shown.map(u.provider.ringColor), shown.map { u.limits[$0].percent })
    }

    /// Seconds between polls. `defaults write com.chocksy.llmactivity pollInterval 30` to change; floor 15.
    var pollInterval: TimeInterval {
        let v = d.double(forKey: "pollInterval")
        return v == 0 ? 60 : max(15, v)
    }

    private init() {
        monochrome = d.bool(forKey: "monochrome")
        showWidget = d.bool(forKey: "showWidget")
        widgetStyle = d.string(forKey: "widgetStyle").flatMap(WidgetStyle.init(rawValue:)) ?? .card
        edgeSide = d.string(forKey: "edgeSide").flatMap(EdgeSide.init(rawValue:)) ?? .right
        disabled = Set((d.array(forKey: "disabledProviders") as? [String] ?? []).compactMap(Provider.init(rawValue:)))
        hiddenLimits = Set(d.stringArray(forKey: "hiddenLimits") ?? [])
        stripLimit = d.dictionary(forKey: "stripLimit") as? [String: String] ?? [:]
    }
}
