import Foundation

/// A parsed unified diff, the domain the diff overlay draws. design/screens/Diff.png.
public struct FileDiff: Identifiable, Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case modified = "M", added = "A", deleted = "D", renamed = "R"
    }

    public var id: String { "\(repo?.slug ?? "")/\(path)" }
    public var repo: Repo?
    public var path: String
    public var oldPath: String?
    public var status: Status
    public var hunks: [Hunk]
    public var binary: Bool
    /// Has staged changes (marked with a filled dot).
    public var staged: Bool

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .deleted } } }
}

public struct Hunk: Hashable, Sendable {
    public var header: String
    public var oldStart: Int
    public var newStart: Int
    public var lines: [DiffLine]
}

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case context, added, deleted }

    public var kind: Kind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String
    /// The changed part of a line paired with its counterpart (character offsets), for word-level highlights.
    public var changed: Range<Int>?
}

/// What the Diff tab compares.
public enum DiffScope: Hashable, Sendable {
    /// What is not committed yet, staged or not (new files too), vs HEAD: what the next commit could hold.
    case uncommitted
    /// Everything since the merge-base with the base branch: commits plus uncommitted work.
    case all
    /// Commits on the branch, vs the merge-base.
    case committed
    case staged
    case unstaged
    case commit(String)

    /// What a Diff tab opens on.
    public static let `default`: DiffScope = .uncommitted
    public static let cycle: [DiffScope] = [.uncommitted, .all, .committed, .staged, .unstaged]

    public var title: String {
        switch self {
        case .uncommitted: "Uncommitted"
        case .all: "All"
        case .committed: "Committed"
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case let .commit(sha): sha
        }
    }

    /// The scope `delta` steps along `cycle` (a commit counts as the start of it).
    public func cycled(by delta: Int) -> DiffScope {
        let cycle = Self.cycle
        let index = cycle.firstIndex(of: self) ?? 0
        return cycle[((index + delta) % cycle.count + cycle.count) % cycle.count]
    }

    /// Whether files git does not track yet belong to it: they are changes in the working tree, not in the index.
    public var includesUntracked: Bool {
        switch self {
        case .uncommitted, .all, .unstaged: true
        case .committed, .staged, .commit: false
        }
    }

    /// The `git` arguments that print this scope as a unified diff; `mergeBase` is the branch's merge-base with main.
    public func gitArguments(mergeBase: String) -> [String] {
        switch self {
        case .uncommitted: ["diff", "--no-color", "-M", "HEAD"]
        case .all: ["diff", "--no-color", "-M", mergeBase]
        case .committed: ["diff", "--no-color", "-M", "\(mergeBase)..HEAD"]
        case .staged: ["diff", "--no-color", "-M", "--cached"]
        case .unstaged: ["diff", "--no-color", "-M"]
        case let .commit(sha): ["show", "--no-color", "-M", "--format=", sha]
        }
    }

    /// Where the two sides of a file come from: the merge view shows both whole files.
    public func sources(mergeBase: String) -> (old: DiffSource, new: DiffSource) {
        switch self {
        case .uncommitted: (.revision("HEAD"), .workingTree)
        case .all: (.revision(mergeBase), .workingTree)
        case .committed: (.revision(mergeBase), .revision("HEAD"))
        case .staged: (.revision("HEAD"), .index)
        case .unstaged: (.index, .workingTree)
        case let .commit(sha): (.revision("\(sha)^"), .revision(sha))
        }
    }
}

/// One side of a file in a scope.
public enum DiffSource: Hashable, Sendable {
    /// A commit (or anything `git show <rev>:<path>` takes).
    case revision(String)
    /// What is staged (`git show :<path>`).
    case index
    /// The file on disk.
    case workingTree

    /// The object `git show` / `git cat-file` read for `path`; nil for the working tree.
    public func object(_ path: String) -> String? {
        switch self {
        case let .revision(rev): "\(rev):\(path)"
        case .index: ":\(path)"
        case .workingTree: nil
        }
    }
}

public struct CommitSummary: Hashable, Sendable, Identifiable {
    public var id: String { sha }
    public var sha: String
    public var subject: String
}

public enum DiffParser {
    /// Parses `git diff` output (no color, default context).
    public static func parse(_ text: String, repo: Repo? = nil, staged: Set<String> = []) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: Hunk?
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            if let finished = hunk { current?.hunks.append(withWordHighlights(finished)) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let file = current { files.append(file) }
            current = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flushFile()
                let path = line.components(separatedBy: " b/").last ?? ""
                current = FileDiff(
                    repo: repo, path: path, oldPath: nil, status: .modified, hunks: [], binary: false,
                    staged: staged.contains(path)
                )
            } else if line.hasPrefix("new file mode") {
                current?.status = .added
            } else if line.hasPrefix("deleted file mode") {
                current?.status = .deleted
            } else if line.hasPrefix("rename from ") {
                current?.status = .renamed
                current?.oldPath = String(line.dropFirst(12))
            } else if line.hasPrefix("Binary files") {
                current?.binary = true
            } else if line.hasPrefix("@@") {
                flushHunk()
                let (old, new) = parseHeader(line)
                oldLine = old
                newLine = new
                hunk = Hunk(header: line, oldStart: old, newStart: new, lines: [])
            } else if hunk != nil {
                if line.hasPrefix("+") {
                    hunk?.lines.append(DiffLine(
                        kind: .added,
                        oldNumber: nil,
                        newNumber: newLine,
                        text: String(line.dropFirst())
                    ))
                    newLine += 1
                } else if line.hasPrefix("-") {
                    hunk?.lines.append(DiffLine(
                        kind: .deleted,
                        oldNumber: oldLine,
                        newNumber: nil,
                        text: String(line.dropFirst())
                    ))
                    oldLine += 1
                } else if line.hasPrefix(" ") {
                    hunk?.lines.append(DiffLine(
                        kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(line.dropFirst())
                    ))
                    oldLine += 1
                    newLine += 1
                }
            }
        }
        flushFile()
        return files
    }

    /// `@@ -76,9 +76,16 @@ …` → (76, 76).
    static func parseHeader(_ line: String) -> (Int, Int) {
        let parts = line.split(separator: " ")
        func start(_ part: Substring?) -> Int {
            guard let part else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "0") ?? 0
        }
        return (start(parts.count > 1 ? parts[1] : nil), start(parts.count > 2 ? parts[2] : nil))
    }

    /// Pairs each run of deleted lines with the added run after it, line by line, and marks what differs between
    /// the pair: everything between their common prefix and suffix.
    static func withWordHighlights(_ hunk: Hunk) -> Hunk {
        var hunk = hunk
        var index = 0
        while index < hunk.lines.count {
            guard hunk.lines[index].kind == .deleted else {
                index += 1
                continue
            }
            let deletedStart = index
            while index < hunk.lines.count, hunk.lines[index].kind == .deleted {
                index += 1
            }
            let addedStart = index
            while index < hunk.lines.count, hunk.lines[index].kind == .added {
                index += 1
            }
            let pairs = min(addedStart - deletedStart, index - addedStart)
            for offset in 0 ..< pairs {
                let (old, new) = changedRanges(
                    hunk.lines[deletedStart + offset].text,
                    hunk.lines[addedStart + offset].text
                )
                hunk.lines[deletedStart + offset].changed = old
                hunk.lines[addedStart + offset].changed = new
            }
        }
        return hunk
    }

    static func changedRanges(_ old: String, _ new: String) -> (Range<Int>?, Range<Int>?) {
        let a = Array(old)
        let b = Array(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let oldRange = prefix < a.count - suffix ? prefix ..< a.count - suffix : nil
        let newRange = prefix < b.count - suffix ? prefix ..< b.count - suffix : nil
        // A pair that shares almost nothing is a rewrite, not an edit: no word highlight.
        let shared = prefix + suffix
        guard shared * 3 >= min(a.count, b.count) else { return (nil, nil) }
        return (oldRange, newRange)
    }

    /// Splits a hunk into side-by-side rows: context on both sides, deleted on the left, added on the right.
    public static func splitRows(_ hunk: Hunk) -> [(left: DiffLine?, right: DiffLine?)] {
        var rows: [(DiffLine?, DiffLine?)] = []
        var deleted: [DiffLine] = []
        var added: [DiffLine] = []
        func flush() {
            for index in 0 ..< max(deleted.count, added.count) {
                rows.append((index < deleted.count ? deleted[index] : nil, index < added.count ? added[index] : nil))
            }
            deleted = []
            added = []
        }
        for line in hunk.lines {
            switch line.kind {
            case .deleted: deleted.append(line)
            case .added: added.append(line)
            case .context:
                flush()
                rows.append((line, line))
            }
        }
        flush()
        return rows
    }
}

/// A scope's diff as one read of a checkout: the files, the branch's commits, and the merge-base both were read
/// against, so a file's contents are read against the same base.
public struct DiffSnapshot: Hashable, Sendable {
    public var scope: DiffScope
    public var files: [FileDiff]
    public var commits: [CommitSummary]
    public var mergeBase: String

    public init(scope: DiffScope, files: [FileDiff], commits: [CommitSummary], mergeBase: String) {
        self.scope = scope
        self.files = files
        self.commits = commits
        self.mergeBase = mergeBase
    }
}

public extension Git {
    /// The diff of a worktree for `scope`, against the merge-base with `origin/<base>` (or `<base>`).
    static func diff(at path: String, scope: DiffScope, base: String, repo: Repo?) async throws -> [FileDiff] {
        try await snapshot(at: path, scope: scope, base: base, repo: repo).files
    }

    /// What the Diff tab shows for `scope`: the diff, files git does not track yet as additions (in the scopes that
    /// cover the working tree), and the branch's commits.
    @concurrent static func snapshot(
        at path: String,
        scope: DiffScope,
        base: String,
        repo: Repo?
    ) async throws -> DiffSnapshot {
        let mergeBase = try await mergeBase(at: path, base: base)
        async let text = ProcessRunner.output(
            "git", ["-C", path] + scope.gitArguments(mergeBase: mergeBase), timeout: .seconds(30)
        )
        async let stagedNames = ProcessRunner.output(
            "git",
            ["-C", path, "diff", "--cached", "--name-only"],
            timeout: .seconds(10)
        )
        async let untrackedNames = scope.includesUntracked
            ? ProcessRunner.output(
                "git", ["-C", path, "ls-files", "--others", "--exclude-standard", "-z"], timeout: .seconds(15)
            )
            : ""
        async let commits = (try? Git.commits(at: path, base: base)) ?? []
        let staged = await Set(((try? stagedNames) ?? "").split(separator: "\n").map(String.init))
        var files = try await DiffParser.parse(text, repo: repo, staged: staged)
        let untracked = await ((try? untrackedNames) ?? "").split(separator: "\0").map(String.init)
        let known = Set(files.map(\.path))
        for name in untracked where !known.contains(name) {
            files.append(untrackedFile(name, in: path, repo: repo))
        }
        files.sort { $0.path < $1.path }
        return await DiffSnapshot(scope: scope, files: files, commits: commits, mergeBase: mergeBase)
    }

    /// A file git does not track, as an addition of all its lines (git prints no diff for it).
    internal static func untrackedFile(_ name: String, in root: String, repo: Repo?) -> FileDiff {
        var file = FileDiff(
            repo: repo,
            path: name,
            oldPath: nil,
            status: .added,
            hunks: [],
            binary: false,
            staged: false
        )
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= FileContents.maxBytes, let data = try? Data(contentsOf: url) else { return file }
        if data.contains(0) {
            file.binary = true
            return file
        }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return file }
        file.hunks = [Hunk(
            header: "@@ -0,0 +1,\(lines.count) @@",
            oldStart: 0,
            newStart: 1,
            lines: lines.enumerated().map { index, text in
                DiffLine(kind: .added, oldNumber: nil, newNumber: index + 1, text: String(text))
            }
        )]
        return file
    }

    /// Commits on the branch since it left `base`, newest first.
    static func commits(at path: String, base: String) async throws -> [CommitSummary] {
        let since = try await mergeBase(at: path, base: base)
        let log = try await ProcessRunner.output(
            "git", ["-C", path, "log", "--format=%h%x09%s", "\(since)..HEAD"], timeout: .seconds(15)
        )
        return log.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return CommitSummary(sha: String(parts[0]), subject: String(parts[1]))
        }
    }

    internal static func mergeBase(at path: String, base: String) async throws -> String {
        for candidate in ["origin/\(base)", base] {
            if let sha = try? await ProcessRunner.output(
                "git",
                ["-C", path, "merge-base", "HEAD", candidate],
                timeout: .seconds(10)
            ) {
                return sha.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "HEAD"
    }
}
