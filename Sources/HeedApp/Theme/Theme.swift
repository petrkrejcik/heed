import AppKit
import HeedCore
import Observation
import SwiftUI

/// The design's tokens (design/html/Main.html), each a light and a dark value that follows the app's appearance
/// (`ColorTheme`). Dark is the design's; light is modelled on GitHub's Primer. Mono type for data and keys, system
/// font for chrome.
enum Theme {
    static let bg = Color(light: 0xF6F8FA, dark: 0x111214)
    static let bg2 = Color(light: 0xEEF1F4, dark: 0x15171A)
    static let bg3 = Color(light: 0xE4E8EC, dark: 0x1D2024)
    static let line = Color(light: 0xD8DEE4, dark: 0x272B30)
    static let fg = Color(light: 0x1F2328, dark: 0xE9EAEC)
    static let fg2 = Color(light: 0x4F5862, dark: 0xA6ABB2)
    static let fg3 = Color(light: 0x656D76, dark: 0x848B93)
    static let dim = Color(light: 0x7D8590, dark: 0x7B828A)
    static let pane = Color(light: 0xFFFFFF, dark: 0x0C0D0F)
    static let paneHeader = Color(light: 0xF6F8FA, dark: 0x121316)
    static let paneActive = Color(light: 0x6E7781, dark: 0xAAB0B8)
    static let chip = Color(light: 0xE7EBEF, dark: 0x23272C)
    static let selected = Color(light: 0xDFE4EA, dark: 0x2B2F35)
    static let keyCap = Color(light: 0xFFFFFF, dark: 0x1A1D20)
    static let keyCapBorder = Color(light: 0xD0D7DE, dark: 0x373C43)
    static let inverse = Color(light: 0x24292F, dark: 0xDFE3E8)
    static let ink = Color(light: 0xFFFFFF, dark: 0x101114)
    static let terminalText = Color(light: 0x1F2328, dark: 0xCFD3D8)
    /// The ring on the pane your keys go to (INSERT).
    static let typing = Color(light: 0x1F2328, dark: 0xFFFFFF)
    /// Dims the window behind a dialog or panel, at the opacity each gives it.
    static let scrim = Color(light: 0x57606A, dark: 0x000000)

    // State hues. Org colors never use these.
    static let busy = Color(light: 0x0969DA, dark: 0x67B0F9)
    static let block = Color(light: 0x9A6700, dark: 0xF9BB51)
    static let ask = Color(light: 0x8250DF, dark: 0xC79EF7)
    static let done = Color(light: 0x1A7F37, dark: 0x72D699)
    static let err = Color(light: 0xCF222E, dark: 0xF97770)
    /// Keep cache warm, while on: the flame on the countdown.
    static let warm = Color(light: 0xBC4C00, dark: 0xFF9B54)
    static let hint = Color(light: 0x1B7C83, dark: 0x73DFDF)

    static func modeColor(_ mode: Mode) -> Color {
        switch mode {
        case .normal: inverse
        case .insert: done
        case .visual: block
        case .command: ask
        case .hint: hint
        }
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "JetBrains Mono", size: size) != nil {
            return .custom("JetBrains Mono", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Org and repo colors: hues away from the state hues, so a chip is never mistaken for a status.
enum OrgPalette: String, CaseIterable, Sendable {
    case teal, pink, lime, orange, periwinkle, sky

    var foreground: Color {
        switch self {
        case .teal: Color(light: 0x136B73, dark: 0x73DFDF)
        case .pink: Color(light: 0x99286E, dark: 0xFDB0D4)
        case .lime: Color(light: 0x3F6212, dark: 0xC2D58A)
        case .orange: Color(light: 0x953800, dark: 0xFFB88F)
        case .periwinkle: Color(light: 0x5A47B8, dark: 0xC3C2FF)
        case .sky: Color(light: 0x075E7A, dark: 0x82D7FF)
        }
    }

    var swatch: Color {
        switch self {
        case .teal: Color(light: 0x1B9AAA, dark: 0x3BCFCF)
        case .pink: Color(light: 0xBF3989, dark: 0xF197C2)
        case .lime: Color(light: 0x5A8A1F, dark: 0xADC367)
        case .orange: Color(light: 0xBC4C00, dark: 0xF5A06F)
        case .periwinkle: Color(light: 0x6E5BD2, dark: 0xAFACFF)
        case .sky: Color(light: 0x0A7EA4, dark: 0x59C5F5)
        }
    }

    /// The chip background: 16% of the swatch over the chip base, as in the design.
    var background: Color { swatch.opacity(0.16) }

    /// A stable color for an org, from its name.
    static func automatic(for name: String) -> OrgPalette {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return allCases[sum % allCases.count]
    }
}

extension ColorTheme {
    var appearance: NSAppearance? { NSAppearance(named: self == .dark ? .darkAqua : .aqua) }

    /// Everything follows the app's appearance: SwiftUI and AppKit colours, web views' `prefers-color-scheme`, and
    /// the terminals (`GhosttyRuntime` watches it). Without it, the system's controls and colours would follow macOS.
    @MainActor func apply() { NSApp.appearance = appearance }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Color {
    /// A colour that is `light` or `dark` by the appearance it is drawn in.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(hex: dark) : NSColor(hex: light) })
    }

    /// The colour as drawn in `theme`, for what is not drawn in a view: images, web pages' CSS.
    func resolved(_ theme: ColorTheme) -> NSColor {
        var resolved = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        (theme.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            resolved = NSColor(self).usingColorSpace(.sRGB) ?? resolved
        }
        return resolved
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// CSS's `hsl(hue saturation% lightness%)`, for colours copied from a stylesheet.
    init(hue: Double, saturation: Double, lightness: Double) {
        let value = lightness + saturation * min(lightness, 1 - lightness)
        self.init(
            hue: hue.truncatingRemainder(dividingBy: 360) / 360,
            saturation: value == 0 ? 0 : 2 * (1 - lightness / value),
            brightness: value
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}

/// Heed's tokens in a bundled web page (Diff, Files, Note), as the CSS variables it reads: both themes, dark by
/// default and light under `prefers-color-scheme: light`, so the page follows the app's appearance by itself.
enum WebTheme {
    /// Sets the variables before the page's own script runs. `html:root` outranks the page's own `:root` defaults.
    static func script(_ variables: (ColorTheme) -> [(String, String)]) -> String {
        func rules(_ theme: ColorTheme) -> String {
            variables(theme).map { "\($0.0): \($0.1);" }.joined(separator: " ")
        }
        let css = "html:root { \(rules(.dark)) } @media (prefers-color-scheme: light) { html:root { \(rules(.light)) } }"
        let literal = String(data: (try? JSONEncoder().encode(css)) ?? Data(), encoding: .utf8) ?? "\"\""
        return """
        (() => {
          const style = document.createElement('style');
          style.textContent = \(literal);
          document.documentElement.appendChild(style);
        })();
        """
    }

    static func css(_ color: Color, _ opacity: Double = 1, _ theme: ColorTheme) -> String {
        let rgb = color.resolved(theme)
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return "rgba(\(channels[0]), \(channels[1]), \(channels[2]), \(opacity))"
    }
}

extension Theme {
    /// A note tag's pill as the vault's Tag Colors plugin paints it on the Kanban (its light theme, as Petr's Obsidian
    /// is): `hsl(hue 65% 88%)` behind `hsl(hue 55% 25%)`. A tag it has not coloured yet is grey.
    static func tagBackground(hue: Int?) -> Color {
        hue.map { Color(hue: Double($0), saturation: 0.65, lightness: 0.88) } ?? Theme.bg3
    }

    static func tagText(hue: Int?) -> Color {
        hue.map { Color(hue: Double($0), saturation: 0.55, lightness: 0.25) } ?? Theme.fg2
    }
}

extension Repo {
    /// The repo's color, picked from the org's name.
    var color: OrgPalette { OrgPalette.automatic(for: org.lowercased()) }
}

/// Org avatars as images, observed so tiles redraw when one arrives. Disk reads and downloads run off the main
/// actor (`AvatarCache`); this only holds decoded images.
@MainActor
@Observable
final class Avatars {
    static let shared = Avatars()
    private(set) var images: [String: NSImage] = [:]
    private var requested: Set<String> = []
    private let cache = AvatarCache.default()

    func image(for org: String) -> NSImage? { images[org.lowercased()] }

    /// Shows cached avatars at once, then refreshes missing or week-old ones in the background.
    func load(_ orgs: [String]) {
        let wanted = Set(orgs.map { $0.lowercased() }).subtracting(requested)
        guard !wanted.isEmpty else { return }
        requested.formUnion(wanted)
        let cache = cache
        Task.detached(priority: .utility) {
            var stale: [String] = []
            for org in wanted {
                if let data = cache.cached(org) { await self.store(org, data) }
                if cache.isStale(org) { stale.append(org) }
            }
            for org in stale {
                if let data = await cache.refresh(org) { await self.store(org, data) }
            }
        }
    }

    private func store(_ org: String, _ data: Data) {
        if let image = NSImage(data: data) { images[org] = image }
    }
}
