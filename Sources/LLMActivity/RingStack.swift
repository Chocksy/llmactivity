import AppKit
import SwiftUI

/// Concentric usage rings, outer ring first. Each ring is a 22%-opacity track
/// plus a trimmed, round-capped arc. The fill animates via SwiftUI's implicit
/// animation on `percents` (Core Animation does the work; the app draws nothing
/// per frame). Each ring gets its own tone from `colors`, and turns amber, then
/// red, as it nears its limit.
struct RingStack: View {
    let colors: [NSColor]
    let percents: [Double]
    var lineWidth: CGFloat = 12
    var gap: CGFloat = 3
    var monochrome: Bool = false

    static let amber = NSColor(srgbRed: 1.0, green: 0.70, blue: 0.13, alpha: 1)
    static let red = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)

    /// Brand tone below 60%, amber by 85%, plain red at 95% and up.
    static func warnColor(_ base: NSColor, percent: Double) -> NSColor {
        guard percent >= 60 else { return base }
        let toAmber = base.blended(withFraction: CGFloat(min((percent - 60) / 25, 1)), of: amber) ?? base
        guard percent > 85 else { return toAmber }
        return toAmber.blended(withFraction: CGFloat(min((percent - 85) / 10, 1)), of: red) ?? toAmber
    }

    var body: some View {
        ZStack {
            ForEach(Array(percents.enumerated()), id: \.offset) { i, p in
                let inset = CGFloat(i) * (lineWidth + gap) + lineWidth / 2
                let c = ringColor(i, p)
                Circle()
                    .stroke(c.opacity(0.22), lineWidth: lineWidth)
                    .padding(inset)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(p, 0), 100) / 100))
                    .stroke(c, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(inset)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.easeOut(duration: 0.9), value: percents)
    }

    private func ringColor(_ i: Int, _ percent: Double) -> Color {
        if monochrome { return .black }
        guard let last = colors.last else { return .black }
        let base = i < colors.count ? colors[i] : last
        return Color(nsColor: Self.warnColor(base, percent: percent))
    }

    /// Static bitmap for the menu bar. Called only when data or the monochrome
    /// setting changes. Monochrome → template image, so macOS tints it like the
    /// system icons (white on dark menu bars, black on light).
    @MainActor
    static func image(colors: [NSColor], percents: [Double], size: CGFloat, monochrome: Bool) -> NSImage {
        let n = max(percents.count, 1)
        // ring widths that still read at 18 pt: 3 rings → 3.2 pt, 2 rings → 4.5 pt
        let lw = (size / 2 - 1) / (CGFloat(n) + 0.35 * CGFloat(n - 1))
        let view = RingStack(colors: colors, percents: percents, lineWidth: lw, gap: lw * 0.35, monochrome: monochrome)
            .frame(width: size, height: size)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let img = renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
        img.size = NSSize(width: size, height: size)
        img.isTemplate = monochrome
        return img
    }
}
