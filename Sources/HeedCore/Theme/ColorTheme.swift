/// Light or dark: the whole window, its terminals and its web views follow it. A UI preference picked by hand
/// (`theme.toggle`), never macOS's appearance.
public enum ColorTheme: String, Sendable, CaseIterable {
    case light, dark

    public static let `default`: ColorTheme = .dark

    public var toggled: ColorTheme { self == .dark ? .light : .dark }

    /// What `theme.toggle` switches to: the theme named in `arguments`, else the other one. Nil for a name it doesn't
    /// know.
    public func next(_ arguments: [String]) -> ColorTheme? {
        guard let name = arguments.first?.lowercased() else { return toggled }
        return ColorTheme(rawValue: name)
    }

    /// The terminal's colours, as a Ghostty theme file (`theme = light:<file>,dark:<file>`). Dark keeps Ghostty's
    /// own palette; light is Ghostty's bundled "GitHub Light Default", with a softer selection.
    public var ghosttyTheme: String {
        switch self {
        case .dark:
            """
            background = #0c0d0f
            foreground = #cfd3d8

            """
        case .light:
            """
            background = #ffffff
            foreground = #1f2328
            cursor-color = #0969da
            cursor-text = #ffffff
            selection-background = #b6e3ff
            selection-foreground = #1f2328
            palette = 0=#24292f
            palette = 1=#cf222e
            palette = 2=#116329
            palette = 3=#4d2d00
            palette = 4=#0969da
            palette = 5=#8250df
            palette = 6=#1b7c83
            palette = 7=#6e7781
            palette = 8=#57606a
            palette = 9=#a40e26
            palette = 10=#1a7f37
            palette = 11=#633c01
            palette = 12=#218bff
            palette = 13=#a475f9
            palette = 14=#3192aa
            palette = 15=#8c959f

            """
        }
    }
}
