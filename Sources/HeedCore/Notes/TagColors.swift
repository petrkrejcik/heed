import Foundation

/// The colours the vault's Tag Colors plugin gives note tags on the Kanban, so a task's tags look the same in Heed.
/// The plugin keeps a colour index per tag in its `data.json` (`assigned`) and turns it into a hue; it assigns a new
/// tag's index itself the first time Obsidian shows it. Heed only reads that file, never writes it.
public struct TagColors: Hashable, Sendable, Codable {
    /// The plugin's `HUES` (`main.js`): red, orange, yellow, green, teal, blue, purple, pink.
    public static let hues = [10, 35, 55, 140, 180, 215, 265, 315]
    /// Where the plugin keeps its data, inside the vault.
    public static let file = ".obsidian/plugins/tag-colors/data.json"

    /// Colour index by tag name, lowercased as the plugin keys them.
    public var assigned: [String: Int]

    public init(assigned: [String: Int] = [:]) {
        self.assigned = assigned
    }

    public static let none = TagColors()

    /// The tag's hue, as the plugin works it out (`#` and case dropped); nil for a tag Obsidian has not coloured yet.
    public func hue(of tag: String) -> Int? {
        let name = (tag.hasPrefix("#") ? String(tag.dropFirst()) : tag).trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard let index = assigned[name], Self.hues.indices.contains(index) else { return nil }
        return Self.hues[index]
    }

    /// The plugin's `data.json`; nil when it is not that shape.
    public static func parse(_ data: Data) -> TagColors? {
        struct File: Decodable { var assigned: [String: Int]? }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return TagColors(assigned: file.assigned ?? [:])
    }

    /// Reads the vault's file off the caller's actor; no colours when the plugin is missing or its file unreadable.
    public static func read(vault: String) async -> TagColors {
        await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: vault).appendingPathComponent(file)
            return (try? Data(contentsOf: url)).flatMap(parse) ?? .none
        }.value
    }

    /// Whether a vault event is the plugin's file being written.
    public static func isFile(_ path: String, vault: String) -> Bool {
        let folder = vault.hasSuffix("/") ? String(vault.dropLast()) : vault
        return path == folder + "/" + file
    }
}
