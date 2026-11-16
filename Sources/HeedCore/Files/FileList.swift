import Foundation

/// Every file of a task's checkout the Files tab shows: what git tracks, what it does not track yet, and what it
/// ignores (greyed), as a normal file tree does; only what `[files] exclude` names is left out. A folder git ignores
/// as a whole (`target/`, `.es/`) is listed as a folder whose contents are read from disk only when it is opened.
///
/// Paths are relative to the checkout and kept sorted by their UTF-8 bytes, as git prints them, so the paths under a
/// folder are one contiguous slice (`FileTree` reads a folder's rows from it). A path ending in `/` is such an unread
/// folder.
public struct FileList: Sendable {
    /// What git says about a file, as VS Code marks it in its tree.
    public enum Mark: String, Hashable, Sendable {
        case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "U"
    }

    public private(set) var paths: [String]
    public private(set) var marks: [String: Mark]
    /// Folders git ignores as a whole (no trailing `/`): they and everything in them are greyed.
    public private(set) var ignoredFolders: Set<String>
    /// Files git ignores one by one (`config/kibana.dev.yml`).
    public private(set) var ignoredFiles: Set<String>
    /// Ignored folders read from disk since (`readingFolder`), so a fresh listing reads them again.
    public private(set) var readFolders: Set<String>
    /// Folders with a changed file somewhere in them (a dot on their row).
    public private(set) var changedFolders: Set<String>
    /// Whether git's status (untracked and ignored files, the marks) is in yet; the tracked files come first.
    public private(set) var complete: Bool
    /// The files for the finder, with their bytes laid out for matching.
    public private(set) var index: PathIndex
    /// Bumped by every change: two lists are the same list when their revisions are, so comparing 134k paths never
    /// happens on a redraw.
    public private(set) var revision: UUID

    public static let empty = FileList(paths: [], complete: false)

    /// `paths` in any order; folders end in `/`. Excluded paths must already be gone (`FileListing` drops them).
    public init(
        paths: [String], marks: [String: Mark] = [:], ignoredFolders: Set<String> = [], ignoredFiles: Set<String> = [],
        readFolders: Set<String> = [], complete: Bool = true
    ) {
        var sorted = paths
        sorted.sort(by: FileList.precedes)
        self.paths = Self.unique(sorted)
        self.marks = marks
        self.ignoredFolders = ignoredFolders
        self.ignoredFiles = ignoredFiles
        self.readFolders = readFolders
        self.complete = complete
        changedFolders = Self.folders(of: marks.keys)
        index = PathIndex(self.paths.filter { !$0.hasSuffix("/") })
        revision = UUID()
    }

    /// The files, without the unread folders.
    public var files: [String] { index.paths }

    public func contains(file path: String) -> Bool {
        let at = lowerBound(path)
        return at < paths.count && paths[at] == path
    }

    /// Whether `path` (a file or a folder) is ignored by git: itself, or a folder it is in.
    public func isIgnored(_ path: String) -> Bool {
        if ignoredFiles.contains(path) || ignoredFolders.contains(path) { return true }
        guard !ignoredFolders.isEmpty else { return false }
        var folder = Substring(path)
        while let slash = folder.lastIndex(of: "/") {
            folder = folder[..<slash]
            if ignoredFolders.contains(String(folder)) { return true }
        }
        return false
    }

    /// Whether `folder` is listed but its contents are not (an ignored folder not read yet).
    public func isUnread(_ folder: String) -> Bool {
        !readFolders.contains(folder) && contains(file: folder + "/")
    }

    /// The same list with `folder`'s entries as read from disk: its files, and its folders as unread folders.
    public func readingFolder(_ folder: String, entries: [(name: String, isFolder: Bool)]) -> FileList {
        var next = self
        let prefix = folder.isEmpty ? "" : folder + "/"
        let added = entries.map { prefix + $0.name + ($0.isFolder ? "/" : "") }
        next.paths = Self.unique((paths + added).sorted(by: Self.precedes))
        next.readFolders.insert(folder)
        next.index = PathIndex(next.paths.filter { !$0.hasSuffix("/") })
        next.revision = UUID()
        return next
    }

    /// Byte order, as git sorts paths: every path under `a/b/` is then in one run.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    /// The first index whose path is not before `key`.
    func lowerBound(_ key: String) -> Int {
        var low = 0, high = paths.count
        while low < high {
            let middle = (low + high) / 2
            if Self.precedes(paths[middle], key) { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The indices of the paths that start with `prefix` (`""`: all of them; else ending in `/`).
    func range(under prefix: String) -> Range<Int> {
        guard !prefix.isEmpty else { return 0 ..< paths.count }
        // The first string after every `a/b/…` is `a/b0`: `0` comes right after `/`.
        let end = String(prefix.dropLast()) + "0"
        return lowerBound(prefix) ..< lowerBound(end)
    }

    private static func unique(_ sorted: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(sorted.count)
        for path in sorted where out.last != path {
            out.append(path)
        }
        return out
    }

    private static func folders(of paths: some Sequence<String>) -> Set<String> {
        var folders: Set<String> = []
        for path in paths {
            var folder = Substring(path)
            while let slash = folder.lastIndex(of: "/") {
                folder = folder[..<slash]
                guard folders.insert(String(folder)).inserted else { break }
            }
        }
        return folders
    }
}

extension FileList: Hashable {
    public static func == (lhs: FileList, rhs: FileList) -> Bool { lhs.revision == rhs.revision }
    public func hash(into hasher: inout Hasher) { hasher.combine(revision) }
}

/// `[files] exclude`: glob patterns on one path component (`node_modules`, `*.log`). A path with a component that
/// matches is never listed, and a folder that matches is never read.
public struct FileExclusion: Hashable, Sendable {
    public static let defaultPatterns = ["node_modules"]

    public let patterns: [String]
    private let names: Set<String>
    private let globs: [String]

    public init(_ patterns: [String] = FileExclusion.defaultPatterns) {
        self.patterns = patterns
        // `.git` is git's own folder, never a file of the checkout.
        let all = patterns + [".git"]
        names = Set(all.filter { !$0.contains(where: { "*?[".contains($0) }) })
        globs = all.filter { $0.contains(where: { "*?[".contains($0) }) }
    }

    public func excludes(name: Substring) -> Bool {
        if names.contains(String(name)) { return true }
        return globs.contains { fnmatch($0, String(name), 0) == 0 }
    }

    /// Whether any component of `path` is excluded (a trailing `/` is a folder's).
    public func excludes(path: String) -> Bool {
        path.split(separator: "/").contains { excludes(name: $0) }
    }
}

/// What `git status --porcelain -z --untracked-files=all --ignored=matching` says, by path.
public struct FileStatus: Hashable, Sendable {
    public var marks: [String: FileList.Mark] = [:]
    /// Untracked files: listed, marked `U`.
    public var untracked: [String] = []
    /// Ignored files, and ignored folders with their trailing `/`.
    public var ignored: [String] = []

    public init(marks: [String: FileList.Mark] = [:], untracked: [String] = [], ignored: [String] = []) {
        self.marks = marks
        self.untracked = untracked
        self.ignored = ignored
    }

    /// Parses porcelain v1 with `-z`: `XY path\0`, and a rename's or copy's old path as one more field.
    public static func parse(_ output: String) -> FileStatus {
        var status = FileStatus()
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let code = field.prefix(2)
            let path = String(field.dropFirst(3))
            let x = code.first ?? " ", y = code.last ?? " "
            if x == "R" || x == "C" { _ = fields.next() }
            switch code {
            case "??":
                status.untracked.append(path)
                status.marks[path] = .untracked
            case "!!":
                status.ignored.append(path)
            default:
                status.marks[path] = x == "D" || y == "D" ? .deleted
                    : x == "A" ? .added
                    : x == "R" || y == "R" ? .renamed
                    : .modified
            }
        }
        return status
    }
}

/// Reads the Files tab's list off the main actor: the tracked files first (fast), then the whole list with git's
/// status (a few seconds on Kibana). The raw output never leaves here.
public enum FileListing {
    /// `git ls-files`: the tracked files only, for the first draw.
    @concurrent public static func tracked(at root: String, exclude: FileExclusion) async throws -> FileList {
        let paths = try await trackedPaths(at: root, exclude: exclude)
        return FileList(paths: paths, complete: false)
    }

    /// Tracked, untracked and ignored files with the marks; ignored folders read before (`reading`) are read again.
    @concurrent public static func full(
        at root: String, exclude: FileExclusion, reading folders: Set<String> = []
    ) async throws -> FileList {
        async let tracked = trackedPaths(at: root, exclude: exclude)
        async let statusText = ProcessRunner.output(
            "git",
            [
                "--no-optional-locks", "-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all",
                "--ignored=matching",
            ],
            timeout: .seconds(60)
        )
        let status = try await FileStatus.parse(statusText)
        return try await list(tracked: tracked, status: status, exclude: exclude, root: root, reading: folders)
    }

    /// The list made from git's answers; `root` is where ignored folders read before are read again.
    static func list(
        tracked: [String], status: FileStatus, exclude: FileExclusion, root: String?, reading folders: Set<String>
    ) -> FileList {
        let ignored = status.ignored.filter { !exclude.excludes(path: $0) }
        let untracked = status.untracked.filter { !exclude.excludes(path: $0) }
        var list = FileList(
            paths: tracked + untracked + ignored,
            marks: status.marks.filter { !exclude.excludes(path: $0.key) },
            ignoredFolders: Set(ignored.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }),
            ignoredFiles: Set(ignored.filter { !$0.hasSuffix("/") })
        )
        guard let root else { return list }
        // Parents sort before their folders, so a folder inside one read again is listed by the time it comes up.
        for folder in folders.sorted(by: FileList.precedes) where list.contains(file: folder + "/") {
            list = list.readingFolder(folder, entries: entries(of: folder, in: root, exclude: exclude))
        }
        return list
    }

    /// An ignored folder opened in the tree: its entries from disk.
    @concurrent public static func reading(
        _ folder: String, in root: String, into list: FileList, exclude: FileExclusion
    ) async -> FileList {
        list.readingFolder(folder, entries: entries(of: folder, in: root, exclude: exclude))
    }

    static func entries(of folder: String, in root: String, exclude: FileExclusion) -> [(
        name: String,
        isFolder: Bool
    )] {
        let url = URL(fileURLWithPath: root).appendingPathComponent(folder)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
        return items.compactMap { item in
            let name = item.lastPathComponent
            guard !exclude.excludes(name: Substring(name)) else { return nil }
            let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return (name, isFolder)
        }
    }

    private static func trackedPaths(at root: String, exclude: FileExclusion) async throws -> [String] {
        let output = try await ProcessRunner.output("git", ["-C", root, "ls-files", "-z"], timeout: .seconds(30))
        return output.split(separator: "\0").compactMap { path in
            exclude.excludes(path: String(path)) ? nil : String(path)
        }
    }
}
