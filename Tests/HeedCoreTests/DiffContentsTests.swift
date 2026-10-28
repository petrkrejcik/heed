import Foundation
@testable import HeedCore
import Testing

@Suite struct DiffContentsTests {
    @Test func scopesReadTheirOwnGitArguments() {
        #expect(DiffScope.default == .uncommitted)
        #expect(DiffScope.uncommitted.gitArguments(mergeBase: "abc") == ["diff", "--no-color", "-M", "HEAD"])
        #expect(DiffScope.all.gitArguments(mergeBase: "abc") == ["diff", "--no-color", "-M", "abc"])
        #expect(DiffScope.committed.gitArguments(mergeBase: "abc") == ["diff", "--no-color", "-M", "abc..HEAD"])
        #expect(DiffScope.staged.gitArguments(mergeBase: "abc") == ["diff", "--no-color", "-M", "--cached"])
        #expect(DiffScope.unstaged.gitArguments(mergeBase: "abc") == ["diff", "--no-color", "-M"])
        #expect(DiffScope.commit("f00").gitArguments(mergeBase: "abc") == [
            "show",
            "--no-color",
            "-M",
            "--format=",
            "f00",
        ])
    }

    @Test func scopesCycleFromUncommitted() {
        #expect(DiffScope.cycle == [.uncommitted, .all, .committed, .staged, .unstaged])
        #expect(DiffScope.uncommitted.cycled(by: 1) == .all)
        #expect(DiffScope.uncommitted.cycled(by: -1) == .unstaged)
        #expect(DiffScope.unstaged.cycled(by: 1) == .uncommitted)
        #expect(DiffScope.commit("f00").cycled(by: 1) == .all)
        #expect(DiffScope.uncommitted.includesUntracked && DiffScope.all.includesUntracked)
        #expect(DiffScope.unstaged.includesUntracked)
        #expect(!DiffScope.staged.includesUntracked && !DiffScope.committed.includesUntracked)
    }

    @Test func scopesCompareTheirTwoSides() {
        #expect(DiffScope.uncommitted.sources(mergeBase: "m") == (.revision("HEAD"), .workingTree))
        #expect(DiffScope.all.sources(mergeBase: "m") == (.revision("m"), .workingTree))
        #expect(DiffScope.committed.sources(mergeBase: "m") == (.revision("m"), .revision("HEAD")))
        #expect(DiffScope.staged.sources(mergeBase: "m") == (.revision("HEAD"), .index))
        #expect(DiffScope.unstaged.sources(mergeBase: "m") == (.index, .workingTree))
        #expect(DiffScope.commit("f00").sources(mergeBase: "m") == (.revision("f00^"), .revision("f00")))
        #expect(DiffSource.revision("HEAD").object("a/b.ts") == "HEAD:a/b.ts")
        #expect(DiffSource.index.object("a/b.ts") == ":a/b.ts")
        #expect(DiffSource.workingTree.object("a/b.ts") == nil)
    }

    @Test func languagesByExtension() {
        #expect(DiffLanguage.of("x/upload_image.ts") == "typescript")
        #expect(DiffLanguage.of("App.tsx") == "tsx")
        #expect(DiffLanguage.of("a.mjs") == "javascript")
        #expect(DiffLanguage.of("a.jsx") == "jsx")
        #expect(DiffLanguage.of("tsconfig.json") == "json")
        #expect(DiffLanguage.of("a.css") == "css")
        #expect(DiffLanguage.of("a.scss") == "scss")
        #expect(DiffLanguage.of("README.MD") == "markdown")
        #expect(DiffLanguage.of(".github/ci.yml") == "yaml")
        #expect(DiffLanguage.of("index.html") == "html")
        #expect(DiffLanguage.of("Makefile") == nil)
    }

    @Test func limitsTurnSidesIntoMessages() {
        #expect(FileContents.side("a\nb\n", bytes: 4) == .text("a\nb\n"))
        #expect(FileContents.side("a\0b", bytes: 3) == .binary)
        #expect(FileContents.side("", bytes: 2_000_000) == .tooLarge(bytes: 2_000_000))
        let lines = String(repeating: "x\n", count: FileContents.maxLines + 1)
        #expect(FileContents.side(lines, bytes: lines.utf8.count) == .tooLarge(bytes: lines.utf8.count))
        #expect(FileContents(path: "a", old: .missing, new: .text("")).unshown == nil)
        #expect(FileContents(path: "a", old: .binary, new: .binary).unshown == "Binary file")
        #expect(FileContents(path: "a", old: .text(""), new: .tooLarge(bytes: 1_500_000)).unshown
            == "Too large to show (1.5 MB)")
    }

    /// One repo with every kind of change: a commit on the branch, then a staged change, an unstaged one on top, a
    /// file git does not track, a deleted file, a renamed one and a binary one.
    @Test func contentsOfEverySide() async throws {
        let repo = try await ThrowawayRepo()
        defer { repo.remove() }
        try repo.write("a.txt", "one\n")
        try repo.write("gone.txt", "bye\n")
        try repo.write("old/name.ts", "export const a = 1\n")
        try repo.write("logo.bin", "PNG\0one")
        try await repo.git("add", ".")
        try await repo.git("commit", "-qm", "base")
        try await repo.git("checkout", "-qb", "feature")
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.git("commit", "-qam", "add two")
        try repo.write("a.txt", "one\ntwo\nstaged\n")
        try await repo.git("rm", "-q", "gone.txt")
        try await repo.git("rm", "-q", "old/name.ts")
        try repo.write("new/name.ts", "export const a = 1\n")
        try repo.write("logo.bin", "PNG\0two")
        try await repo.git("add", ".")
        try repo.write("a.txt", "one\ntwo\nstaged\nworking\n")
        try repo.write("src/fresh.ts", "export const fresh = true\n")

        let uncommitted = try await Git.snapshot(at: repo.path, scope: .uncommitted, base: "main", repo: nil)
        #expect(uncommitted.files.map(\.path) == ["a.txt", "gone.txt", "logo.bin", "new/name.ts", "src/fresh.ts"])
        let a = try #require(uncommitted.files.first { $0.path == "a.txt" })
        #expect(a.additions == 2 && a.staged)
        let fresh = try #require(uncommitted.files.first { $0.path == "src/fresh.ts" })
        #expect(fresh.status == .added && !fresh.staged && fresh.additions == 1)
        #expect(uncommitted.files.first { $0.path == "new/name.ts" }?.oldPath == "old/name.ts")
        #expect(uncommitted.files.first { $0.path == "logo.bin" }?.binary == true)
        #expect(uncommitted.commits.map(\.subject) == ["add two"])

        let staged = try await Git.snapshot(at: repo.path, scope: .staged, base: "main", repo: nil)
        #expect(!staged.files.contains { $0.path == "src/fresh.ts" })
        let unstaged = try await Git.snapshot(at: repo.path, scope: .unstaged, base: "main", repo: nil)
        #expect(unstaged.files.map(\.path) == ["a.txt", "src/fresh.ts"])

        func contents(_ path: String, _ scope: DiffScope) async throws -> FileContents {
            let snapshot = try await Git.snapshot(at: repo.path, scope: scope, base: "main", repo: nil)
            let file = try #require(snapshot.files.first { $0.path == path })
            return await Git.contents(of: file, in: repo.path, scope: scope, mergeBase: snapshot.mergeBase)
        }
        let sides: [(DiffScope, String, String)] = [
            (.uncommitted, "one\ntwo\n", "one\ntwo\nstaged\nworking\n"),
            (.all, "one\n", "one\ntwo\nstaged\nworking\n"),
            (.committed, "one\n", "one\ntwo\n"),
            (.staged, "one\ntwo\n", "one\ntwo\nstaged\n"),
            (.unstaged, "one\ntwo\nstaged\n", "one\ntwo\nstaged\nworking\n"),
            (.commit(uncommitted.commits[0].sha), "one\n", "one\ntwo\n"),
        ]
        for (scope, old, new) in sides {
            let read = try await contents("a.txt", scope)
            #expect(read.old == .text(old), "\(scope) old")
            #expect(read.new == .text(new), "\(scope) new")
        }

        let added = try await contents("src/fresh.ts", .uncommitted)
        #expect(added.old == .missing && added.new == .text("export const fresh = true\n"))
        let deleted = try await contents("gone.txt", .uncommitted)
        #expect(deleted.old == .text("bye\n") && deleted.new == .missing)
        let renamed = try await contents("new/name.ts", .staged)
        #expect(renamed.old == .text("export const a = 1\n") && renamed.new == .text("export const a = 1\n"))
        let binary = try await contents("logo.bin", .uncommitted)
        #expect(binary.unshown == "Binary file")
    }

    @Test func largeFilesAreNotRead() async throws {
        let repo = try await ThrowawayRepo()
        defer { repo.remove() }
        try repo.write("small.txt", "x\n")
        try await repo.git("add", ".")
        try await repo.git("commit", "-qm", "base")
        let big = String(repeating: "0123456789\n", count: 100_000)
        try repo.write("big.txt", big)
        try repo.write("long.txt", String(repeating: "x\n", count: FileContents.maxLines + 1))
        try await repo.git("add", "long.txt")
        try await repo.git("commit", "-qm", "long")

        let snapshot = try await Git.snapshot(at: repo.path, scope: .uncommitted, base: "main", repo: nil)
        let untracked = try #require(snapshot.files.first { $0.path == "big.txt" })
        #expect(untracked.status == .added && untracked.hunks.isEmpty)
        let read = await Git.contents(of: untracked, in: repo.path, scope: .uncommitted, mergeBase: snapshot.mergeBase)
        #expect(read.new == .tooLarge(bytes: big.utf8.count))

        let long = await Git.side("long.txt", from: .revision("HEAD"), in: repo.path)
        #expect(long == .tooLarge(bytes: (FileContents.maxLines + 1) * 2))
        let missing = await Git.side("nowhere.txt", from: .revision("HEAD"), in: repo.path)
        #expect(missing == .missing)
    }
}

/// A git repo in a temp directory, on `main`, with an author set; gone after the test.
struct ThrowawayRepo {
    let path: String

    init() async throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("heed-diff-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main")
        try await git("config", "user.email", "t@t")
        try await git("config", "user.name", "t")
    }

    func write(_ name: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func git(_ arguments: String...) async throws {
        _ = try await ProcessRunner.output("git", ["-C", path] + arguments)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
