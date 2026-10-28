import Foundation

/// Where you are in a file's diff, as the web view reports it: the hunk on screen or the line you clicked.
public struct DiffCursor: Hashable, Sendable {
    public enum Side: String, Hashable, Sendable {
        /// The old file (left in side-by-side).
        case old = "a"
        /// The new file.
        case new = "b"
    }

    public var path: String
    public var line: Int
    public var side: Side
    /// 1-based; 0 when no hunk is on screen.
    public var hunk: Int
    public var hunks: Int

    public init(path: String, line: Int, side: Side = .new, hunk: Int = 0, hunks: Int = 0) {
        self.path = path
        self.line = line
        self.side = side
        self.hunk = hunk
        self.hunks = hunks
    }
}

/// One Diff tab: the scope it shows, the files git listed, the file you are on and its two sides. Lives as long as
/// the tab (not persisted: a relaunch reads it again, on the default scope).
public struct DiffReview: Hashable, Sendable {
    public var scope: DiffScope
    /// In the tree's order, so `]f` walks the files as the list shows them.
    public private(set) var files: [FileDiff] = []
    public private(set) var commits: [CommitSummary] = []
    public private(set) var mergeBase = "HEAD"
    /// The file shown, by path.
    public private(set) var selected: String?
    /// Folders closed in the tree, by folder path.
    public var collapsed: Set<String> = []
    /// The selected file's sides, once read.
    public var contents: FileContents?
    public var cursor: DiffCursor?
    /// A read in flight, and when the last one landed (nil: never, or stale and due again when shown).
    public var loading = false
    public var loadedAt: Date?

    public init(scope: DiffScope = .default) {
        self.scope = scope
    }

    public var selectedFile: FileDiff? { selected.flatMap { path in files.first { $0.path == path } } }
    public var selectedIndex: Int? { selected.flatMap { path in files.firstIndex { $0.path == path } } }
    public var tree: DiffTree { DiffTree(files) }

    /// A fresh read. The file you were on stays selected (and its contents, until they are read again) when it is
    /// still changed; else the first file. Folders it sits in open.
    public mutating func apply(_ snapshot: DiffSnapshot) {
        scope = snapshot.scope
        files = DiffTree(snapshot.files).files
        commits = snapshot.commits
        mergeBase = snapshot.mergeBase
        let keep = selected.flatMap { path in files.contains { $0.path == path } ? path : nil }
        select(keep ?? files.first?.path)
    }

    /// Shows the file at `path` (nil: none), opening the folders it is in.
    public mutating func select(_ path: String?) {
        if path != selected {
            contents = nil
            cursor = nil
        }
        selected = path
        if let path { collapsed.subtract(DiffTree.folders(containing: path, in: tree)) }
    }

    /// `]f` / `[f`: the next or previous file, stopping at either end. False when there is none to go to.
    @discardableResult
    public mutating func moveFile(by delta: Int) -> Bool {
        guard !files.isEmpty else { return false }
        let from = selectedIndex ?? (delta > 0 ? -1 : files.count)
        let to = from + delta
        guard files.indices.contains(to) else { return false }
        select(files[to].path)
        return true
    }

    /// `⇥` / `⇧⇥`: the next scope; the files are read again.
    public mutating func cycleScope(by delta: Int) {
        scope = scope.cycled(by: delta)
        loadedAt = nil
    }

    /// `c`: the branch's commits one at a time, newest first, then back to the default scope. False when there are
    /// none.
    @discardableResult
    public mutating func cycleCommit() -> Bool {
        guard !commits.isEmpty else { return false }
        if case let .commit(sha) = scope, let index = commits.firstIndex(where: { $0.sha == sha }) {
            scope = index + 1 < commits.count ? .commit(commits[index + 1].sha) : .default
        } else {
            scope = .commit(commits[0].sha)
        }
        loadedAt = nil
        return true
    }

    /// The line `a`, `y` and `e` act on: what the web view reported for this file, else its first hunk.
    public var location: (path: String, line: Int)? {
        guard let file = selectedFile else { return nil }
        if let cursor, cursor.path == file.path { return (file.path, max(cursor.line, 1)) }
        return (file.path, max(file.hunks.first?.newStart ?? 1, 1))
    }
}
