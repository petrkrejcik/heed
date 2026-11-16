import Foundation

/// A file and maybe a line in it, as a link from a terminal or a path pasted into the finder names it:
/// `src/foo/bar.ts:12`, `./bar.ts:12:5`, `/Users/me/www/kibana/package.json`, `~/x/y.ts`, `file:///a/b.ts`.
public struct FileLocation: Hashable, Sendable {
    /// Absolute, standardized (no `.` or `..`).
    public var path: String
    public var line: Int?
    public var column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }

    /// `text` as a location, relative paths taken from `root`. Nil when it is not a path: a web link, words with
    /// spaces, or (unless `bare`) a relative path without a `/` (`bar.ts:12` is not a link in a terminal).
    public static func parse(_ text: String, root: String, home: String = NSHomeDirectory(), bare: Bool = false)
        -> FileLocation?
    {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Quoted or ending a sentence: "`a/b.ts:12`," and "a/b.ts:12:" (as compilers print them).
        let quotes = CharacterSet(charactersIn: "`'\"<>()[]")
        while true {
            var trimmed = text.trimmingCharacters(in: quotes)
            while let last = trimmed.last, ",;:.".contains(last) {
                trimmed.removeLast()
            }
            if trimmed == text { break }
            text = trimmed
        }
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if text.hasPrefix("file:") {
            if let url = URL(string: text), url.isFileURL {
                text = url.path(percentEncoded: false)
            } else {
                text = String(text.dropFirst(5))
            }
            if text.hasPrefix("//") { text = String(text.dropFirst(2)) }
        } else if let scheme = text.range(of: "://"), !text[..<scheme.lowerBound].contains("/") {
            return nil
        }
        var line: Int?
        var column: Int?
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 3, let l = Int(parts[parts.count - 2]), let c = Int(parts[parts.count - 1]) {
            line = l
            column = c
            text = parts.dropLast(2).joined(separator: ":")
        } else if parts.count >= 2, let l = Int(parts[parts.count - 1]) {
            line = l
            text = parts.dropLast().joined(separator: ":")
        }
        guard !text.isEmpty else { return nil }
        let absolute: String
        if text == "~" || text.hasPrefix("~/") {
            absolute = home + text.dropFirst()
        } else if text.hasPrefix("/") {
            absolute = text
        } else {
            let explicit = text.hasPrefix("./") || text.hasPrefix("../")
            guard bare || explicit || text.contains("/") else { return nil }
            absolute = (root as NSString).appendingPathComponent(text)
        }
        return FileLocation(
            path: (absolute as NSString).standardizingPath, line: line.map { max($0, 1) }, column: column
        )
    }

    /// The path inside `root`, relative to it; nil when it is outside (or is `root` itself).
    public func relative(to root: String) -> String? {
        let base = (root as NSString).standardizingPath
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
