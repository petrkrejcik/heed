import Foundation

/// A note ready to render: its markdown, where its wikilinks point and what its `![[embeds]]` show. Built off the main
/// actor from the file and the note index; the Note tab's page draws it.
public struct NoteDocument: Sendable, Equatable {
    public enum Embed: Sendable, Equatable {
        /// Another note's markdown (shown one level deep).
        case note(String)
        /// A file of the vault, e.g. a pasted image.
        case file(String)
    }

    public var markdown: String
    public var path: String
    /// The inside of each `[[…]]` (as written) → the note's absolute path, nil when no note has that name.
    public var links: [String: String?]
    /// The inside of each `![[…]]` (as written) → what it shows; missing when nothing matched.
    public var embeds: [String: Embed]

    public init(markdown: String, path: String, links: [String: String?] = [:], embeds: [String: Embed] = [:]) {
        self.markdown = markdown
        self.path = path
        self.links = links
        self.embeds = embeds
    }

    /// Reads the note at `path` and resolves its links and embeds. `read` returns a note's text; `findFile` an
    /// attachment's absolute path for a name as written in `![[…]]`. Blocks on IO: call it off the main actor.
    public static func load(
        path: String, entries: [NoteEntry], read: (String) -> String?, findFile: (String) -> String?
    ) -> NoteDocument {
        let markdown = read(path) ?? ""
        var embeds: [String: Embed] = [:]
        var texts = [markdown]
        for raw in matches(of: embedPattern, in: markdown) where embeds[raw] == nil {
            let target = WikilinkResolver.Parsed(raw: raw).target
            let ext = (target as NSString).pathExtension.lowercased()
            if !ext.isEmpty, ext != "md" {
                if imageExtensions.contains(ext), let file = findFile(target) { embeds[raw] = .file(file) }
            } else if let note = WikilinkResolver.resolve(raw, in: entries), note != path, let text = read(note) {
                embeds[raw] = .note(text)
                texts.append(text)
            }
        }
        var links: [String: String?] = [:]
        for text in texts {
            links.merge(WikilinkResolver.resolveAll(in: text, entries: entries)) { first, _ in first }
        }
        return NoteDocument(markdown: markdown, path: path, links: links, embeds: embeds)
    }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "avif"]

    private static func matches(of pattern: NSRegularExpression, in text: String) -> [String] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // swiftlint:disable:next force_try
    private static let embedPattern = try! NSRegularExpression(pattern: #"!\[\[([^\]\n]+)\]\]"#)
}

public extension NoteIndex {
    /// Where Obsidian finds an attachment written as `name` in a note at `notePath`: that path in the vault, next to
    /// the note, else the first file of that name anywhere in the vault (dot folders skipped). Blocks on IO.
    static func findFile(_ name: String, notePath: String, vault: String) -> String? {
        let files = FileManager.default
        let noteFolder = (notePath as NSString).deletingLastPathComponent
        for candidate in [
            (vault as NSString).appendingPathComponent(name),
            (noteFolder as NSString).appendingPathComponent(name),
        ]
            where files.fileExists(atPath: candidate)
        {
            return candidate
        }
        let wanted = (name as NSString).lastPathComponent.lowercased()
        guard let walker = files.enumerator(
            at: URL(fileURLWithPath: vault), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in walker where url.lastPathComponent.lowercased() == wanted {
            return url.path
        }
        return nil
    }
}
