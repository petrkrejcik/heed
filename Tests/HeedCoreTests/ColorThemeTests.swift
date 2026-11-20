@testable import HeedCore
import Testing

struct ColorThemeTests {
    @Test func toggleSwitchesToTheOtherOrTheNamedOne() {
        #expect(ColorTheme.dark.next([]) == .light)
        #expect(ColorTheme.light.next([]) == .dark)
        #expect(ColorTheme.dark.next(["dark"]) == .dark)
        #expect(ColorTheme.dark.next(["Light"]) == .light)
        #expect(ColorTheme.dark.next(["sepia"]) == nil)
    }

    @Test func darkIsTheDefault() {
        #expect(ColorTheme.default == .dark)
    }

    @Test func themeAliasAndKey() {
        #expect(CommandAliases.resolve("theme light") == CommandInvocation(name: "theme.toggle", arguments: ["light"]))
        #expect(DefaultKeys.normal.contains { $0 == ("zt", "theme.toggle") })
    }

    /// The pane colours live only in the theme files: a `background` in the overrides would win over the theme.
    @Test func terminalThemesSetTheirColours() {
        for theme in ColorTheme.allCases {
            let lines = theme.ghosttyTheme.split(separator: "\n")
            #expect(lines.contains { $0.hasPrefix("background = #") })
            #expect(lines.contains { $0.hasPrefix("foreground = #") })
        }
        #expect(ColorTheme.light.ghosttyTheme.split(separator: "\n").count(where: { $0.hasPrefix("palette = ") }) == 16)
        #expect(ColorTheme.dark.ghosttyTheme.contains("background = #0c0d0f"))
    }
}
