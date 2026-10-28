import Foundation

/// Both whole versions of one file in a scope: what the Diff tab's merge view compares.
public struct FileContents: Hashable, Sendable {
    public enum Side: Hashable, Sendable {
        case text(String)
        /// The file does not exist on this side (added, deleted).
        case missing
        case binary
        /// Over `maxBytes` or `maxLines`: shown as a message, not a diff.
        case tooLarge(bytes: Int)

        public var text: String? {
            if case let .text(text) = self { return text }
            return nil
        }
    }

    public var path: String
    public var old: Side
    public var new: Side

    public init(path: String, old: Side, new: Side) {
        self.path = path
        self.old = old
        self.new = new
    }

    /// Larger files get a message instead of a diff: a merge view of them would be slow and unreadable anyway.
    public static let maxBytes = 1_000_000
    public static let maxLines = 20000

    /// Why the diff is not drawn, or nil when both sides are text (or missing).
    public var unshown: String? {
        for side in [old, new] {
            switch side {
            case .binary: return "Binary file"
            case let .tooLarge(bytes): return "Too large to show (\(Self.size(bytes)))"
            case .text, .missing: continue
            }
        }
        return nil
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : "\(bytes / 1000) KB"
    }

    /// Text as read, checked against the limits.
    static func side(_ text: String, bytes: Int) -> Side {
        if text.contains("\0") { return .binary }
        if bytes > maxBytes { return .tooLarge(bytes: bytes) }
        if text.utf8.lazy.count(where: { $0 == 10 }) > maxLines { return .tooLarge(bytes: bytes) }
        return .text(text)
    }
}

/// The language the Diff tab highlights a file as, by its extension; the web view maps each name to a CodeMirror
/// language. Nil is plain text.
public enum DiffLanguage {
    public static func of(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "ts", "mts", "cts": return "typescript"
        case "tsx": return "tsx"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "jsx"
        case "json", "jsonc", "json5": return "json"
        case "css", "less": return "css"
        case "scss": return "scss"
        case "sass": return "sass"
        case "md", "mdx", "markdown": return "markdown"
        case "yml", "yaml": return "yaml"
        case "html", "htm": return "html"
        default: return name == ".babelrc" || name == ".eslintrc" ? "json" : nil
        }
    }
}

public extension Git {
    /// Both sides of `file` in `scope` (against `mergeBase`, as its diff was read): `git show <rev>:<path>`, the index
    /// with `git show :<path>`, the working tree from disk. A side the file does not exist on is `.missing`.
    @concurrent static func contents(
        of file: FileDiff, in root: String, scope: DiffScope, mergeBase: String
    ) async -> FileContents {
        let sources = scope.sources(mergeBase: mergeBase)
        let oldPath = file.oldPath ?? file.path
        async let old: FileContents.Side = file.status == .added
            ? .missing : side(oldPath, from: sources.old, in: root, binary: file.binary)
        async let new: FileContents.Side = file.status == .deleted
            ? .missing : side(file.path, from: sources.new, in: root, binary: file.binary)
        return await FileContents(path: file.path, old: old, new: new)
    }

    @concurrent internal static func side(
        _ path: String, from source: DiffSource, in root: String, binary: Bool = false
    ) async -> FileContents.Side {
        if binary { return .binary }
        guard let object = source.object(path) else {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return .missing }
            if size > FileContents.maxBytes { return .tooLarge(bytes: size) }
            guard let data = try? Data(contentsOf: url) else { return .missing }
            if data.contains(0) { return .binary }
            return FileContents.side(String(decoding: data, as: UTF8.self), bytes: data.count)
        }
        guard let sizeText = try? await ProcessRunner.output(
            "git", ["-C", root, "cat-file", "-s", object], timeout: .seconds(10)
        ), let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .missing }
        if size > FileContents.maxBytes { return .tooLarge(bytes: size) }
        guard let text = try? await ProcessRunner.output("git", ["-C", root, "show", object], timeout: .seconds(20))
        else { return .missing }
        return FileContents.side(text, bytes: size)
    }
}
