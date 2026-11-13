import Foundation

/// One entry in the note index: a vault `.md` file.
public struct NoteEntry: Sendable, Equatable {
    /// Absolute path to the `.md` file.
    public var path: String
    /// The filename without extension (e.g. `"My note"`).
    public var name: String
    /// Vault-relative path without extension (e.g. `"Projects/My note"`), for resolution.
    public var relativePath: String
    /// Aliases from the note's frontmatter (`aliases:` list).
    public var aliases: [String]
    /// The folder component of the vault-relative path (e.g. `"Projects"`), empty for the vault root.
    public var folder: String
    /// Last-modified time of the file.
    public var modifiedAt: Date

    public init(
        path: String, name: String, relativePath: String, aliases: [String] = [],
        folder: String = "", modifiedAt: Date = .distantPast
    ) {
        self.path = path
        self.name = name
        self.relativePath = relativePath
        self.aliases = aliases
        self.folder = folder
        self.modifiedAt = modifiedAt
    }
}

/// Builds and maintains an index of every `.md` file under a vault root (skipping dot folders).
/// All scanning runs off the main actor; results are plain value types.
public enum NoteIndex {
    // MARK: Scanning

    /// Builds a fresh index by scanning `vault` recursively. Skips dot folders.
    public static func scan(vault: String) async -> [NoteEntry] {
        await Task.detached(priority: .userInitiated) {
            var entries: [NoteEntry] = []
            scanDirectory(vault, vault: vault, into: &entries)
            return entries
        }.value
    }

    private static func scanDirectory(_ dir: String, vault: String, into entries: inout [NoteEntry]) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in contents {
            // Skip dot items.
            guard !name.hasPrefix(".") else { continue }
            let fullPath = dir + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                scanDirectory(fullPath, vault: vault, into: &entries)
            } else if name.hasSuffix(".md") {
                if let entry = makeEntry(path: fullPath, vault: vault) {
                    entries.append(entry)
                }
            }
        }
    }

    private static func makeEntry(path: String, vault: String) -> NoteEntry? {
        let url = URL(fileURLWithPath: path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modifiedAt = attrs?[.modificationDate] as? Date ?? .distantPast
        let fileName = url.deletingPathExtension().lastPathComponent
        // Vault-relative path without extension.
        let vaultPrefix = vault.hasSuffix("/") ? vault : vault + "/"
        guard path.hasPrefix(vaultPrefix) else { return nil }
        let relativeWithExt = String(path.dropFirst(vaultPrefix.count))
        let relative = (relativeWithExt as NSString).deletingPathExtension
        let folder = (relative as NSString).deletingLastPathComponent
        let aliases = readAliases(from: path)
        return NoteEntry(
            path: path, name: fileName, relativePath: relative,
            aliases: aliases, folder: folder, modifiedAt: modifiedAt
        )
    }

    // MARK: Frontmatter parsing

    /// Reads the `aliases:` list from YAML frontmatter (the first `---` block).
    static func readAliases(from path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return extractAliases(from: text)
    }

    /// Parses aliases from markdown text (exposed for testing).
    public static func extractAliases(from text: String) -> [String] {
        // Frontmatter starts at the very beginning with `---` and ends with another `---` or `...`.
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }
        lines.removeFirst()
        var inAliases = false
        var aliases: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { break }
            if inAliases {
                if trimmed.hasPrefix("-") {
                    let value = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { aliases.append(String(value)) }
                } else if trimmed.contains(":") {
                    // Another key started — stop collecting aliases.
                    inAliases = false
                }
            } else if trimmed.hasPrefix("aliases:") {
                let after = trimmed.dropFirst("aliases:".count).trimmingCharacters(in: .whitespaces)
                if after.hasPrefix("[") {
                    // Inline: aliases: [one, two]
                    let inner = after.dropFirst().split(separator: "]").first ?? ""
                    aliases = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                } else if !after.isEmpty {
                    // Single value: aliases: one
                    aliases = [String(after)]
                } else {
                    inAliases = true
                }
            }
        }
        return aliases
    }

    // MARK: Incremental updates

    /// Applies `events` from FSEvents to `entries`, returning an updated list.
    /// Only processes non-directory `.md` events outside dot folders.
    public static func applying(_ events: [FileEvent], to entries: [NoteEntry], vault: String) -> [NoteEntry] {
        var result = entries
        for event in events {
            guard !event.isDirectory else { continue }
            guard event.path.hasSuffix(".md") else { continue }
            guard !isDotPath(event.path) else { continue }
            if event.structural {
                // Could be create, delete or rename — rebuild this path.
                result.removeAll { $0.path == event.path }
                if let entry = makeEntry(path: event.path, vault: vault) {
                    result.append(entry)
                }
            } else {
                // Modification: re-read aliases and mtime.
                if let idx = result.firstIndex(where: { $0.path == event.path }),
                   let entry = makeEntry(path: event.path, vault: vault)
                {
                    result[idx] = entry
                }
            }
        }
        return result
    }

    private static func isDotPath(_ path: String) -> Bool {
        path.components(separatedBy: "/").contains { $0.hasPrefix(".") && !$0.isEmpty }
    }
}

// MARK: Wikilink resolution

/// Resolves Obsidian-style wikilinks against an index of notes.
/// Rules (in priority order):
/// 1. Exact vault-relative path match (with or without `.md`).
/// 2. By filename, case-insensitive; shortest vault-relative path wins.
/// 3. By alias, case-insensitive; shortest path wins.
public enum WikilinkResolver {
    /// Parses `"target#heading|alias"` into its parts.
    public struct Parsed: Equatable, Sendable {
        /// The raw link target (path or name), without heading or alias.
        public var target: String
        /// The `#heading` part, without the `#`.
        public var heading: String?
        /// The `|alias` part, without the `|`.
        public var alias: String?

        public init(raw: String) {
            var s = raw
            // Strip alias first (last `|`).
            if let pipe = s.lastIndex(of: "|") {
                alias = String(s[s.index(after: pipe)...])
                s = String(s[..<pipe])
            }
            // Then heading (first `#`).
            if let hash = s.firstIndex(of: "#") {
                heading = String(s[s.index(after: hash)...])
                s = String(s[..<hash])
            }
            target = s
        }
    }

    /// Resolves `raw` wikilink against `entries`. Returns the absolute path, or nil when unresolved.
    public static func resolve(_ raw: String, in entries: [NoteEntry]) -> String? {
        let parsed = Parsed(raw: raw)
        let target = parsed.target
        guard !target.isEmpty else { return nil }

        // 1. Exact vault-relative path (with or without .md extension).
        let targetNoExt = target.hasSuffix(".md") ? String(target.dropLast(3)) : target
        if let exact = entries.first(where: { $0.relativePath == targetNoExt }) {
            return exact.path
        }

        // 2. By name, case-insensitive, shortest path wins.
        let lower = target.lowercased()
        let byName = entries
            .filter { $0.name.lowercased() == lower }
            .sorted { $0.relativePath.count < $1.relativePath.count }
        if let best = byName.first { return best.path }

        // 3. By alias, case-insensitive, shortest path wins.
        let byAlias = entries
            .filter { $0.aliases.contains { $0.lowercased() == lower } }
            .sorted { $0.relativePath.count < $1.relativePath.count }
        return byAlias.first?.path
    }

    /// Returns the absolute paths of all wikilinks in `text` as a dict `target -> absolutePath?`.
    public static func resolveAll(in text: String, entries: [NoteEntry]) -> [String: String?] {
        var result: [String: String?] = [:]
        for match in wikilinkPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[range])
            if result[raw] == nil {
                result[raw] = resolve(raw, in: entries)
            }
        }
        return result
    }

    private static let wikilinkPattern: NSRegularExpression = // Matches [[content]] — non-greedy, no newlines inside.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)
}
