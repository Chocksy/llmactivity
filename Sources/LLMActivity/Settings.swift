import AppKit
import Combine

enum WidgetStyle: String { case card, edge }

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var monochrome: Bool { didSet { d.set(monochrome, forKey: "monochrome") } }
    @Published var showWidget: Bool { didSet { d.set(showWidget, forKey: "showWidget") } }
    @Published var widgetStyle: WidgetStyle { didSet { d.set(widgetStyle.rawValue, forKey: "widgetStyle") } }
    /// Providers the user hid, so the menu bar does not get crowded.
    @Published var disabled: Set<Provider> { didSet { d.set(disabled.map(\.rawValue), forKey: "disabledProviders") } }

    /// Single limits the user hid ("claude.weekly_scoped"), e.g. a model they stopped using.
    @Published var hiddenLimits: Set<String> { didSet { d.set(Array(hiddenLimits), forKey: "hiddenLimits") } }

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
        disabled = Set((d.array(forKey: "disabledProviders") as? [String] ?? []).compactMap(Provider.init(rawValue:)))
        hiddenLimits = Set(d.stringArray(forKey: "hiddenLimits") ?? [])
    }
}
