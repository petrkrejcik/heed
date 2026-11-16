import Foundation

/// `gf` / `p`: the file finder, over every file of the task's list. Modal, like the note picker; the matching runs
/// off the main actor (`FileFinder.rows`) and its answer lands with `show`, unless the query moved on meanwhile.
public struct FileFinder: Hashable, Sendable {
    public struct Row: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            /// The query is the path of a file (pasted, `a/b.ts:12`).
            case location
            /// Opened in the tab before (the empty query).
            case recent
            /// Changed in git (the empty query, after the recent ones).
            case changed
            case match
        }

        public var id: String { "\(path):\(line ?? 0)" }
        public var path: String
        public var line: Int?
        public var column: Int?
        public var kind: Kind

        public init(path: String, line: Int? = nil, column: Int? = nil, kind: Kind) {
            self.path = path
            self.line = line
            self.column = column
            self.kind = kind
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The key was taken; the rows may have moved.
        case handled
        /// The query changed: match it again.
        case search
        case cancel
        case open(Row)
    }

    public private(set) var query: String
    public private(set) var rows: [Row] = []
    /// The query `rows` answer.
    public private(set) var answered: String?
    public private(set) var cursor = 0

    public init(query: String = "") {
        self.query = query
    }

    /// The rows for `query`, unless it is no longer the query.
    public mutating func show(_ rows: [Row], for query: String) {
        guard query == self.query else { return }
        self.rows = rows
        answered = query
        cursor = 0
    }

    public mutating func paste(_ text: String) {
        query += text.trimmingCharacters(in: .newlines)
    }

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        switch stroke {
        case .escape, KeyStroke("q", .control):
            return .cancel
        case KeyStroke("CR"):
            // The rows of an older query are not what you see opening.
            guard answered == query, rows.indices.contains(cursor) else { return .handled }
            return .open(rows[cursor])
        case KeyStroke("n", .control), KeyStroke("j", .control), KeyStroke("Down"):
            cursor = min(cursor + 1, max(rows.count - 1, 0))
        case KeyStroke("p", .control), KeyStroke("k", .control), KeyStroke("Up"):
            cursor = max(cursor - 1, 0)
        case KeyStroke("w", .control):
            var words = query.split(separator: " ", omittingEmptySubsequences: true)
            if !words.isEmpty { words.removeLast() }
            query = words.joined(separator: " ")
            return .search
        case KeyStroke("u", .control):
            query = ""
            return .search
        case KeyStroke("BS"):
            guard !query.isEmpty else { return .handled }
            query.removeLast()
            return .search
        default:
            if stroke.isNamed {
                guard stroke.key == "Space", stroke.modifiers.isEmpty else { return .handled }
                query += " "
                return .search
            }
            guard stroke.modifiers.isEmpty || stroke.modifiers == [.shift] else { return .handled }
            query += stroke.key
            return .search
        }
        return .handled
    }

    /// The matcher's last answer, kept so a longer query searches only what matched the shorter one.
    public struct Narrowing: Sendable {
        public var query: String
        public var revision: UUID
        public var matched: [Int32]

        public init(query: String, revision: UUID, matched: [Int32]) {
            self.query = query
            self.revision = revision
            self.matched = matched
        }
    }

    /// What the finder lists for `query`: a path that names a file first (`exists` checks one the list lacks, as a
    /// file in `node_modules`), then the matches; for an empty query the files opened in the tab, then the changed
    /// ones. Nil when cancelled. Runs off the main actor.
    public static func rows(
        _ query: String, list: FileList, root: String, recent: [String], home: String = NSHomeDirectory(),
        narrowing: Narrowing? = nil, exists: (String) -> Bool
    ) -> (rows: [Row], narrowing: Narrowing?)? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            var seen: Set<String> = []
            var rows = recent.filter { seen.insert($0).inserted }.map { Row(path: $0, kind: .recent) }
            let changed = list.marks.filter { $0.value != .deleted }.keys.sorted(by: FileList.precedes)
            rows += changed.filter { seen.insert($0).inserted }.map { Row(path: $0, kind: .changed) }
            return (rows, nil)
        }
        var rows: [Row] = []
        if let location = FileLocation.parse(trimmed, root: root, home: home, bare: true),
           let path = location.relative(to: root), list.contains(file: path) || exists(path)
        {
            rows.append(Row(path: path, line: location.line, column: location.column, kind: .location))
        }
        let lowered = query.lowercased()
        let among = narrowing.flatMap { previous in
            previous.revision == list.revision && lowered.hasPrefix(previous.query) ? previous.matched : nil
        }
        guard let found = PathMatcher.search(lowered, in: list.index, among: among) else { return nil }
        rows += found.top.filter { $0.path != rows.first?.path }.map { Row(path: $0.path, kind: .match) }
        return (rows, Narrowing(query: lowered, revision: list.revision, matched: found.matched))
    }
}
