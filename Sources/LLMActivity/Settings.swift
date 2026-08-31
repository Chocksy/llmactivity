import Foundation
import Combine

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var monochrome: Bool { didSet { d.set(monochrome, forKey: "monochrome") } }
    @Published var showWidget: Bool { didSet { d.set(showWidget, forKey: "showWidget") } }
    /// Providers the user hid, so the menu bar does not get crowded.
    @Published var disabled: Set<Provider> { didSet { d.set(disabled.map(\.rawValue), forKey: "disabledProviders") } }

    func isEnabled(_ p: Provider) -> Bool { !disabled.contains(p) }
    func setEnabled(_ p: Provider, _ on: Bool) {
        if on { disabled.remove(p) } else { disabled.insert(p) }
    }

    /// Seconds between polls. `defaults write com.chocksy.llmactivity pollInterval 30` to change; floor 15.
    var pollInterval: TimeInterval {
        let v = d.double(forKey: "pollInterval")
        return v == 0 ? 60 : max(15, v)
    }

    private init() {
        monochrome = d.bool(forKey: "monochrome")
        showWidget = d.bool(forKey: "showWidget")
        disabled = Set((d.array(forKey: "disabledProviders") as? [String] ?? []).compactMap(Provider.init(rawValue:)))
    }
}
