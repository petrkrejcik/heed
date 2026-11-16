import Foundation

/// One Files tab: what its left side shows (the tree or search results), where you are in it, and the file on the
/// right. Lives as long as the tab; only the open file is saved (the pane's `path`), so a relaunch reads it again.
public struct FilesBrowser: Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        case files, search

        public var other: Mode { self == .files ? .search : .files }
    }

    public var mode: Mode = .files
    /// Folders open in the tree, by path.
    public var open: Set<String> = []
    /// The tree row `j`/`k` are on.
    public var cursor: String?
    /// The file shown, relative to the checkout.
    public private(set) var file: String?
    /// The line asked for (a link, a match), marked and scrolled to; nil: the top.
    public private(set) var line: Int?
    public private(set) var column: Int?
    /// Bumped by every `show`, so going to the same line again scrolls there again.
    public private(set) var visit = 0
    /// `file`'s text once read (`Git.side`'s limits: binary, too large, missing).
    public var text: FileContents.Side?
    /// Files shown in this tab, newest first: the finder's empty query starts with them.
    public private(set) var recent: [String] = []
    public var search = SearchResults()
    /// When the open file was last read; nil: never, or due again when shown.
    public var readAt: Date?

    public init(file: String? = nil) {
        if let file { show(file) }
    }

    /// Shows `path` at `line` (and `column`), opening the folders it is in and putting the tree cursor on it. The
    /// text is read again when it is another file.
    public mutating func show(_ path: String, line: Int? = nil, column: Int? = nil) {
        if path != file {
            text = nil
            readAt = nil
        }
        file = path
        self.line = line
        self.column = column
        visit += 1
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > 50 { recent.removeLast() }
        open.formUnion(FileTree.ancestors(of: path))
        cursor = FileTree.Row.id(file: path)
    }

    /// `j` / `k` in the tree.
    public mutating func moveCursor(by delta: Int, rows: [FileTree.Row]) {
        guard !rows.isEmpty else { return }
        let at = cursor.flatMap { id in rows.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : rows.count)
        cursor = rows[max(0, min(at + delta, rows.count - 1))].id
    }

    /// The row the cursor is on (the first row when it is on none).
    public func cursorRow(_ rows: [FileTree.Row]) -> FileTree.Row? {
        cursor.flatMap { id in rows.first { $0.id == id } } ?? rows.first
    }

    /// `l` / `↩` on a folder: open it, or go into it when it is open. Returns the folder to read from disk when it
    /// is an unread ignored one.
    @discardableResult
    public mutating func unfold(_ row: FileTree.Row, rows: [FileTree.Row]) -> String? {
        guard case let .folder(isOpen, unread) = row.kind else { return nil }
        cursor = row.id
        if !isOpen {
            open.insert(row.path)
            return unread ? row.path : nil
        }
        if let index = rows.firstIndex(of: row), rows.indices.contains(index + 1), rows[index + 1].depth > row.depth {
            cursor = rows[index + 1].id
        }
        return nil
    }

    /// `h`: closes the open folder you are on, else goes up to the folder you are in.
    public mutating func fold(rows: [FileTree.Row]) {
        guard let row = cursorRow(rows) else { return }
        if case .folder(open: true, _) = row.kind {
            open.remove(row.path)
            cursor = row.id
        } else if let parent = FileTree.parentRow(of: row.id, in: rows) {
            cursor = parent.id
        }
    }

    /// A click on a folder's row.
    @discardableResult
    public mutating func toggle(_ row: FileTree.Row) -> String? {
        guard case let .folder(isOpen, unread) = row.kind else { return nil }
        cursor = row.id
        if isOpen {
            open.remove(row.path)
            return nil
        }
        open.insert(row.path)
        return unread ? row.path : nil
    }

    /// `path:line` for `y` and `a`: the line asked for, else the first.
    public var location: (path: String, line: Int)? {
        file.map { ($0, max(line ?? 1, 1)) }
    }
}

/// Find in files: the query, the lines ripgrep found so far grouped by file in the order they came, and the one you
/// are on.
public struct SearchResults: Hashable, Sendable {
    public private(set) var query = ""
    /// Every line, file by file.
    public private(set) var matches: [SearchMatch] = []
    public var running = false
    /// Stopped at `FileSearch.limit`.
    public private(set) var capped = false
    public private(set) var binaryFiles = 0
    public var error: String?
    /// The match `j`/`k`/`n`/`N` are on, by index into `matches`.
    public var cursor: Int?
    /// Typing the query (`/`): keys go to it, not to commands.
    public var typing = false

    public init() {}

    public mutating func type(_ query: String) {
        self.query = query
    }

    public enum Edit: Equatable, Sendable {
        /// The query changed: search it once typing pauses.
        case changed
        /// `↩`: search now and open the first match.
        case submit
        /// `⎋`: typing ends, the results stay.
        case stop
        case ignored
    }

    /// A key while the query is typed (`/`).
    public mutating func edit(_ stroke: KeyStroke) -> Edit {
        let before = query
        switch stroke {
        case .escape:
            typing = false
            return .stop
        case KeyStroke("CR"):
            typing = false
            return .submit
        case KeyStroke("BS"):
            if !query.isEmpty { query.removeLast() }
        case KeyStroke("u", .control):
            query = ""
        case KeyStroke("w", .control):
            var words = query.split(separator: " ")
            if !words.isEmpty { words.removeLast() }
            query = words.joined(separator: " ")
        case KeyStroke("Space"):
            query += " "
        default:
            guard !stroke.isNamed, stroke.modifiers.isEmpty || stroke.modifiers == [.shift] else { return .ignored }
            query += stroke.key
        }
        return query == before ? .ignored : .changed
    }

    /// A new search: the old results go.
    public mutating func start() {
        matches = []
        capped = false
        binaryFiles = 0
        error = nil
        cursor = nil
        running = !query.isEmpty
    }

    public mutating func add(_ events: [SearchEvent]) {
        for event in events {
            switch event {
            case let .match(match):
                matches.append(match)
            case let .binary(path):
                matches.removeAll { $0.path == path }
                binaryFiles += 1
            }
        }
        if matches.count >= FileSearch.limit { capped = true }
    }

    /// The files in the order they came, each with its lines.
    public var files: [(path: String, matches: [SearchMatch])] {
        var groups: [(path: String, matches: [SearchMatch])] = []
        for match in matches {
            if groups.last?.path == match.path {
                groups[groups.count - 1].matches.append(match)
            } else {
                groups.append((match.path, [match]))
            }
        }
        return groups
    }

    public var fileCount: Int { files.count }

    /// `n` / `N` (and `j` / `k` in the results): the next or previous match, across files, stopping at either end.
    /// Nil when there is none to go to.
    public mutating func move(by delta: Int) -> SearchMatch? {
        guard !matches.isEmpty else { return nil }
        let from = cursor ?? (delta > 0 ? -1 : matches.count)
        let to = from + delta
        guard matches.indices.contains(to) else { return nil }
        cursor = to
        return matches[to]
    }

    public var current: SearchMatch? { cursor.flatMap { matches.indices.contains($0) ? matches[$0] : nil } }
}
