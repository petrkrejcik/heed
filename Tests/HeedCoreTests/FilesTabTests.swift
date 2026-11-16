import Foundation
@testable import HeedCore
import Testing

private func rowNames(_ rows: [FileTree.Row]) -> [String] {
    rows.map { row in
        let indent = String(repeating: "  ", count: row.depth)
        switch row.kind {
        case let .folder(open, unread): return indent + row.name + (unread ? "/?" : open ? "/" : "/…")
        case let .file(mark): return indent + row.name + (mark.map { " \($0.rawValue)" } ?? "")
        }
    }
}

struct FileTreeTests {
    private let list = FileList(
        paths: [
            "x-pack/plugins/chat/public/upload.ts", "x-pack/plugins/chat/public/components/button.scss",
            "x-pack/plugins/chat/server/routes/attachments.ts", "x-pack/plugins/chat/README.md", "package.json",
            "x-pack/plugins/chat/public/upload.test.ts", "x-pack/plugins/chat/target/", "config/kibana.yml",
            "config/kibana.dev.yml", "config-b.json",
        ],
        marks: [
            "x-pack/plugins/chat/public/upload.ts": .modified,
            "x-pack/plugins/chat/public/upload.test.ts": .untracked,
        ],
        ignoredFolders: ["x-pack/plugins/chat/target"], ignoredFiles: ["config/kibana.dev.yml"]
    )

    @Test func onlyTheRootIsBuiltUntilAFolderOpens() {
        #expect(rowNames(FileTree.rows(list, open: [])) == [
            "config/…",
            "x-pack/plugins/chat/…",
            "config-b.json",
            "package.json",
        ])
    }

    @Test func foldersFirstAndSingleFolderChainsShareARow() {
        let rows = FileTree.rows(list, open: ["x-pack/plugins/chat", "x-pack/plugins/chat/public", "config"])
        #expect(rowNames(rows) == [
            "config/",
            "  kibana.dev.yml",
            "  kibana.yml",
            "x-pack/plugins/chat/",
            "  public/",
            "    components/…",
            "    upload.test.ts U",
            "    upload.ts M",
            "  server/routes/…",
            "  target/?",
            "  README.md",
            "config-b.json",
            "package.json",
        ])
        // Changed files mark the folders they are in; ignored ones are greyed, inside an ignored folder too.
        #expect(rows.first { $0.path == "x-pack/plugins/chat" }?.changed == true)
        #expect(rows.first { $0.path == "config" }?.changed == false)
        #expect(rows.first { $0.path == "config/kibana.dev.yml" }?.ignored == true)
        #expect(rows.first { $0.path == "config/kibana.yml" }?.ignored == false)
        #expect(list.isIgnored("x-pack/plugins/chat/target/main.js"))
        #expect(rows.first { $0.id == "d:x-pack/plugins/chat/server/routes" } != nil)
    }

    @Test func showingADeepFileOpensTheFoldersItIsIn() {
        var browser = FilesBrowser()
        browser.show("x-pack/plugins/chat/public/components/button.scss", line: 12)
        let rows = FileTree.rows(list, open: browser.open)
        #expect(browser.cursorRow(rows)?.path == "x-pack/plugins/chat/public/components/button.scss")
        #expect(rowNames(rows).contains("      button.scss"))
        #expect(browser.location?.line == 12)
        #expect(browser.recent == ["x-pack/plugins/chat/public/components/button.scss"])
    }

    @Test func anIgnoredFolderIsReadWhenOpened() {
        var browser = FilesBrowser()
        browser.open = ["x-pack/plugins/chat"]
        var rows = FileTree.rows(list, open: browser.open)
        guard let target = rows.first(where: { $0.path == "x-pack/plugins/chat/target" }) else {
            Issue.record("no target row")
            return
        }
        #expect(browser.unfold(target, rows: rows) == "x-pack/plugins/chat/target")
        let read = list.readingFolder("x-pack/plugins/chat/target", entries: [("index.js", false), ("types", true)])
        rows = FileTree.rows(read, open: browser.open)
        #expect(rowNames(rows).contains("    types/?"))
        #expect(rowNames(rows).contains("    index.js"))
        #expect(read.files.contains("x-pack/plugins/chat/target/index.js"))
        #expect(!read.isUnread("x-pack/plugins/chat/target") && read.isUnread("x-pack/plugins/chat/target/types"))
    }

    @Test func hFoldsOrGoesUpAndLGoesIn() {
        var browser = FilesBrowser()
        browser.open = ["config"]
        var rows = FileTree.rows(list, open: browser.open)
        browser.cursor = FileTree.Row.id(file: "config/kibana.yml")
        browser.fold(rows: rows)
        #expect(browser.cursor == "d:config")
        browser.fold(rows: rows)
        #expect(browser.open.isEmpty)
        rows = FileTree.rows(list, open: browser.open)
        browser.unfold(rows[0], rows: rows)
        rows = FileTree.rows(list, open: browser.open)
        browser.unfold(rows[0], rows: rows)
        #expect(browser.cursor == "f:config/kibana.dev.yml")
        browser.moveCursor(by: 1, rows: rows)
        #expect(browser.cursor == "f:config/kibana.yml")
        browser.moveCursor(by: 100, rows: rows)
        #expect(browser.cursor == rows.last?.id)
    }

    @Test func excludedPathsNeverShow() {
        let exclusion = FileExclusion(["node_modules", "*.log"])
        #expect(exclusion.excludes(path: "node_modules/react/index.js"))
        #expect(exclusion.excludes(path: "a/b/node_modules/"))
        #expect(exclusion.excludes(path: "logs/debug.log"))
        #expect(exclusion.excludes(path: ".git/HEAD"))
        #expect(!exclusion.excludes(path: "src/node_modules_list.ts"))
        #expect(!exclusion.excludes(path: ".gitignore"))
    }
}

struct PathMatcherTests {
    private func ranked(_ query: String, _ paths: [String]) -> [String] {
        PathMatcher.search(query, in: PathIndex(paths))?.top.map(\.path) ?? []
    }

    @Test func eachWordIsASubsequenceAnywhere() {
        let paths = ["src/plugins/chat/upload.ts", "src/plugins/chat/download.ts", "README.md"]
        #expect(ranked("upl", paths) == ["src/plugins/chat/upload.ts"])
        #expect(Set(ranked("chat load", paths)) == ["src/plugins/chat/upload.ts", "src/plugins/chat/download.ts"])
        #expect(ranked("load chat", paths).count == 2)
        #expect(ranked("zzz", paths).isEmpty)
        #expect(ranked("UPL", paths) == ["src/plugins/chat/upload.ts"])
    }

    @Test func theFileNameScoresOverFolders() {
        let paths = ["upload/handlers/index.ts", "src/handlers/upload.ts"]
        #expect(ranked("upload", paths).first == "src/handlers/upload.ts")
    }

    @Test func wordStartsAndRunsScoreHigher() {
        // `ui` at the starts of `upload_image` beats a `u…i` spread inside one word.
        #expect(ranked("ui", ["src/build_info.ts", "src/upload_image.ts"]).first == "src/upload_image.ts")
        // A run beats the same letters scattered.
        #expect(ranked("chat", ["c/h/a/t.ts", "x/chat.ts"]).first == "x/chat.ts")
        // camelCase starts count.
        #expect(ranked("ub", ["src/uploadbutton.ts", "src/UploadButton.tsx"]).first == "src/UploadButton.tsx")
        // Ties: the shorter path.
        #expect(ranked("a", ["x/y/a.ts", "x/a.ts"]).first == "x/a.ts")
    }

    @Test func aLongerQuerySearchesOnlyWhatMatchedBefore() throws {
        let index = PathIndex(["a/upload.ts", "a/update.ts", "b/other.ts"])
        let first = try #require(PathMatcher.search("up", in: index))
        #expect(first.matched.count == 2)
        let next = try #require(PathMatcher.search("upl", in: index, among: first.matched))
        #expect(next.top.map(\.path) == ["a/upload.ts"])
    }

    /// 134k paths shaped like Kibana's: 8 folders deep on average (up to 15), `.ts`/`.tsx` mostly, and as dense in
    /// matches (`chatin` matches about half, as it matches 61k of Kibana's 134,761).
    static let kibanaSized: [String] = {
        var generator = SystemRandomNumberGenerator()
        let words = [
            "x-pack", "platform", "plugins", "shared", "src", "core", "packages", "public", "server", "common",
            "components", "hooks", "utils", "lib", "routes", "services", "api", "chat", "onechat", "agent_builder",
            "security", "solution", "observability", "management", "data", "views", "discover", "lens", "maps",
            "kbn-test", "kbn-i18n", "kbn-ui", "http", "browser", "saved_objects", "alerting", "fleet", "cases",
            "timeline", "conversation", "attachments", "upload", "settings", "embeddable", "dashboard", "visualize",
        ]
        let names = [
            "index", "types", "constants", "plugin", "helpers", "use_fetch", "use_upload", "upload_image", "button",
            "flyout", "panel", "table", "header", "footer", "conversation_list", "chat_input", "message", "router",
            "schema", "mocks", "config", "utils", "request_handler", "query_bar", "empty_state", "loading",
        ]
        let extensions = ["ts", "ts", "ts", "tsx", "tsx", "test.ts", "json", "md", "scss", "js"]
        var paths = Set<String>()
        while paths.count < 134_000 {
            let depth = Int.random(in: 1 ... 15, using: &generator)
            var parts = (0 ..< depth).map { _ in words.randomElement(using: &generator)! }
            let name = names.randomElement(using: &generator)!
            let suffix = Int.random(in: 0 ... 40, using: &generator)
            parts.append("\(name)\(suffix == 0 ? "" : "_\(suffix)").\(extensions.randomElement(using: &generator)!)")
            paths.insert(parts.joined(separator: "/"))
        }
        return paths.sorted(by: FileList.precedes)
    }()

    @Test func matching134kPathsIsWellUnderATenthOfASecondPerKey() throws {
        let index = PathIndex(Self.kibanaSized)
        var slowest: Duration = .zero
        for query in ["upload image", "chatinput", "x pack onechat hooks use upload", "agent_builder/conv list"] {
            // Typed key by key, each key searching what the last one matched, as the finder does.
            var narrowing: [Int32]?
            var typed = ""
            for character in query {
                typed.append(character)
                let clock = ContinuousClock()
                var result: (top: [PathMatcher.Match], matched: [Int32])?
                let took = clock.measure {
                    result = PathMatcher.search(typed, in: index, among: narrowing)
                }
                narrowing = result?.matched
                slowest = max(slowest, took)
            }
            #expect(try #require(PathMatcher.search(query, in: index)).top.count <= 50)
        }
        // The worst case: a first key, over everything.
        for query in ["u", "e", "s"] {
            let clock = ContinuousClock()
            slowest = max(slowest, clock.measure { _ = PathMatcher.search(query, in: index) })
        }
        print("PathMatcher: slowest key over 134k paths: \(slowest)")
        #expect(slowest < Self.budget, "slowest key took \(slowest)")
    }

    /// What the app (a release build) must stay well under: 11 ms on an M-series Mac, measured with
    /// `swift test -c release -Xswiftc -enable-testing --filter matching134k`. A debug build pays a call for every
    /// byte (about 340 ms), so there the bound only catches a slower algorithm.
    #if DEBUG
        static let budget: Duration = .milliseconds(1000)
    #else
        static let budget: Duration = .milliseconds(100)
    #endif
}

struct FileFinderTests {
    private let list = FileList(
        paths: ["src/upload.ts", "src/download.ts", "config/kibana.yml"], marks: ["src/upload.ts": .modified]
    )

    @Test func aPastedPathWithALineIsTheFirstRow() throws {
        let rows = try #require(FileFinder.rows(
            "/w/kibana/config/kibana.yml:12", list: list, root: "/w/kibana", recent: [], exists: { _ in false }
        )?.rows)
        #expect(rows.first == FileFinder.Row(path: "config/kibana.yml", line: 12, kind: .location))
        let relative = try #require(FileFinder.rows(
            "src/upload.ts:4:2", list: list, root: "/w/kibana", recent: [], exists: { _ in false }
        )?.rows)
        #expect(relative.first == FileFinder.Row(path: "src/upload.ts", line: 4, column: 2, kind: .location))
        #expect(relative.count == 1)
        // Not in the list (ignored, in node_modules) but on disk: still first.
        let unlisted = try #require(FileFinder.rows(
            "node_modules/react/index.js", list: list, root: "/w/kibana", recent: [],
            exists: { $0 == "node_modules/react/index.js" }
        )?.rows)
        #expect(unlisted.first?.kind == .location)
        // Outside the checkout: only what it matches.
        let outside = try #require(FileFinder.rows(
            "/etc/hosts", list: list, root: "/w/kibana", recent: [], exists: { _ in true }
        )?.rows)
        #expect(!outside.contains { $0.kind == .location })
    }

    @Test func theEmptyQueryIsTheTabsFilesThenTheChangedOnes() throws {
        let rows = try #require(FileFinder.rows(
            "", list: list, root: "/w", recent: ["config/kibana.yml", "src/upload.ts"], exists: { _ in false }
        )?.rows)
        #expect(rows.map(\.path) == ["config/kibana.yml", "src/upload.ts"])
        #expect(rows.map(\.kind) == [.recent, .recent])
        let fresh = try #require(FileFinder.rows("", list: list, root: "/w", recent: [], exists: { _ in false })?.rows)
        #expect(fresh == [FileFinder.Row(path: "src/upload.ts", kind: .changed)])
    }

    @Test func keysTypeIntoTheQueryAndOnlyAnsweredRowsOpen() {
        var finder = FileFinder()
        for key in ["j", "k", "u", "G"] {
            #expect(finder.handle(KeyStroke(key)) == .search)
        }
        #expect(finder.query == "jkuG")
        #expect(finder.handle(KeyStroke("CR")) == .handled)
        finder.show([FileFinder.Row(path: "a", kind: .match), FileFinder.Row(path: "b", kind: .match)], for: "old")
        #expect(finder.rows.isEmpty)
        finder.show([FileFinder.Row(path: "a", kind: .match), FileFinder.Row(path: "b", kind: .match)], for: "jkuG")
        #expect(finder.handle(KeyStroke("j", .control)) == .handled)
        #expect(finder.handle(KeyStroke("CR")) == .open(FileFinder.Row(path: "b", kind: .match)))
        #expect(finder.handle(KeyStroke("w", .control)) == .search && finder.query.isEmpty)
        #expect(finder.handle(.escape) == .cancel)
    }
}

struct FileLocationTests {
    private let root = "/Users/me/www/kibana"

    @Test func pathsWithLinesAndColumns() {
        #expect(FileLocation.parse("src/foo/bar.ts:12", root: root)
            == FileLocation(path: "\(root)/src/foo/bar.ts", line: 12))
        #expect(FileLocation.parse("./bar.ts:12:5", root: root) == FileLocation(
            path: "\(root)/bar.ts",
            line: 12,
            column: 5
        ))
        #expect(FileLocation.parse("../other/x.ts", root: root) == FileLocation(path: "/Users/me/www/other/x.ts"))
        #expect(FileLocation.parse("~/notes/a.md:3", root: root, home: "/Users/me")
            == FileLocation(path: "/Users/me/notes/a.md", line: 3))
        #expect(FileLocation.parse("/abs/a.ts", root: root) == FileLocation(path: "/abs/a.ts"))
        #expect(FileLocation.parse("file:///Users/me/www/kibana/a%20b.ts", root: root)
            == FileLocation(path: "\(root)/a b.ts"))
        // As compilers print them, or quoted in a sentence.
        #expect(FileLocation.parse("src/a.ts:4:2:", root: root) == FileLocation(
            path: "\(root)/src/a.ts",
            line: 4,
            column: 2
        ))
        #expect(FileLocation.parse("`src/a.ts:4`,", root: root) == FileLocation(path: "\(root)/src/a.ts", line: 4))
    }

    @Test func notPaths() {
        #expect(FileLocation.parse("https://github.com/elastic/kibana", root: root) == nil)
        #expect(FileLocation.parse("upload image", root: root) == nil)
        // A bare name is not a link (Ghostty needs a `/`), but the finder takes it.
        #expect(FileLocation.parse("bar.ts:12", root: root) == nil)
        #expect(FileLocation.parse("bar.ts:12", root: root, bare: true) == FileLocation(
            path: "\(root)/bar.ts",
            line: 12
        ))
    }

    @Test func insideTheCheckoutOrNot() {
        let inside = FileLocation(path: "\(root)/src/a.ts")
        #expect(inside.relative(to: root) == "src/a.ts")
        #expect(inside.relative(to: root + "/") == "src/a.ts")
        #expect(FileLocation(path: "/Users/me/www/kibana-other/a.ts").relative(to: root) == nil)
        #expect(FileLocation(path: root).relative(to: root) == nil)
        #expect(FileLocation.parse("/Users/me/www/kibana/../x/a.ts", root: root)?.relative(to: root) == nil)
    }
}

struct RipgrepParserTests {
    private func line(_ object: String) -> Data { Data((object + "\n").utf8) }

    @Test func matchesWithSeveralPerLine() {
        var parser = RipgrepParser()
        let events = parser.feed(
            line(#"{"type":"begin","data":{"path":{"text":"./src/a.ts"}}}"#)
                +
                line(
                    #"{"type":"match","data":{"path":{"text":"./src/a.ts"},"lines":{"text":"    const upload = upload(x);\n"},"line_number":7,"absolute_offset":10,"submatches":[{"match":{"text":"upload"},"start":10,"end":16},{"match":{"text":"upload"},"start":19,"end":25}]}}"#
                )
                + line(#"{"type":"end","data":{"path":{"text":"./src/a.ts"},"binary_offset":null,"stats":{}}}"#)
                + line(#"{"type":"summary","data":{"stats":{}}}"#)
        )
        #expect(events == [.match(SearchMatch(
            path: "src/a.ts", line: 7, column: 11, text: "const upload = upload(x);", ranges: [6 ..< 12, 15 ..< 21]
        ))])
    }

    @Test func aBinaryFileIsReported() {
        var parser = RipgrepParser()
        let events = parser.feed(line(
            #"{"type":"end","data":{"path":{"text":"img.png"},"binary_offset":1024,"stats":{}}}"#
        ))
        #expect(events == [.binary(path: "img.png")])
        var results = SearchResults()
        results.type("x")
        results.start()
        results.add([.match(SearchMatch(path: "img.png", line: 1, column: 1, text: "x", ranges: [0 ..< 1]))])
        results.add(events)
        #expect(results.matches.isEmpty && results.binaryFiles == 1)
    }

    @Test func aLineCutAcrossChunksWaitsForTheRest() {
        var parser = RipgrepParser()
        let whole =
            line(
                #"{"type":"match","data":{"path":{"text":"a.ts"},"lines":{"text":"abc\n"},"line_number":1,"submatches":[{"match":{"text":"b"},"start":1,"end":2}]}}"#
            )
        let half = whole.count / 2
        #expect(parser.feed(whole.prefix(half)).isEmpty)
        #expect(parser.feed(whole.suffix(from: half)).count == 1)
        // Stopped mid-line: what is left is dropped.
        #expect(parser.feed(whole.prefix(half)).isEmpty)
        #expect(parser.finish().isEmpty)
    }

    @Test func bytesThatAreNotUTF8AndLongLines() {
        var parser = RipgrepParser()
        let base64 = Data("caf\u{e9} x".utf8).base64EncodedString()
        let events = parser.feed(line(
            #"{"type":"match","data":{"path":{"bytes":"\#(Data("b.ts".utf8).base64EncodedString())"},"lines":{"bytes":"\#(base64)"},"line_number":2,"submatches":[{"match":{"text":"x"},"start":6,"end":7}]}}"#
        ))
        guard case let .match(match) = events.first else {
            Issue.record("no match")
            return
        }
        #expect(match.path == "b.ts" && match.text == "café x" && match.column == 6)
        let long = String(repeating: "a", count: 1000) + "needle" + String(repeating: "b", count: 1000)
        let cut = RipgrepParser.shown(path: "c", line: 1, raw: long, ranges: [1000 ..< 1006])
        #expect(cut.text.utf8.count <= RipgrepParser.maxLine)
        #expect(cut.ranges.count == 1)
        let range = cut.ranges[0]
        let bytes = Array(cut.text.utf8)
        #expect(String(decoding: bytes[range], as: UTF8.self) == "needle")
        #expect(cut.column == 1001)
    }

    @Test func ripgrepIsLiteralAndSmartCase() {
        let arguments = FileSearch.arguments("a.b(", exclude: FileExclusion())
        #expect(arguments.contains("--fixed-strings") && arguments.contains("--smart-case"))
        #expect(arguments.suffix(3) == ["--", "a.b(", "."])
        #expect(arguments.contains("!node_modules"))
    }

    @Test func searchResultsMoveAcrossFiles() {
        var results = SearchResults()
        results.type("x")
        results.start()
        #expect(results.running)
        func match(_ path: String, _ line: Int) -> SearchEvent {
            .match(SearchMatch(path: path, line: line, column: 1, text: "x", ranges: [0 ..< 1]))
        }
        results.add([match("a.ts", 1), match("a.ts", 5), match("b.ts", 2)])
        #expect(results.files.map(\.path) == ["a.ts", "b.ts"])
        #expect(results.move(by: 1)?.line == 1)
        #expect(results.move(by: 1)?.line == 5)
        #expect(results.move(by: 1)?.path == "b.ts")
        #expect(results.move(by: 1) == nil)
        #expect(results.move(by: -1)?.line == 5)
    }
}

struct FileListingTests {
    @Test func aCheckoutListsTrackedUntrackedAndIgnoredButNotExcluded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heed-files-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let files = FileManager.default
        for folder in ["src", "node_modules/react", "target/sub", "config"] {
            try files.createDirectory(atPath: "\(root)/\(folder)", withIntermediateDirectories: true)
        }
        func write(_ path: String, _ text: String = "x\n") throws {
            try text.write(toFile: "\(root)/\(path)", atomically: true, encoding: .utf8)
        }
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            _ = try await ProcessRunner.output("git", ["-C", root] + args)
        }
        try write(".gitignore", "node_modules/\ntarget/\nconfig/*.dev.yml\n")
        try write("src/a.ts")
        try write("src/b.ts")
        try write("config/kibana.yml")
        _ = try await ProcessRunner.output("git", ["-C", root, "add", "."])
        _ = try await ProcessRunner.output("git", ["-C", root, "commit", "-q", "-m", "one"])
        try write("src/a.ts", "changed\n")
        try write("src/new.ts")
        try write("config/kibana.dev.yml")
        try write("node_modules/react/index.js")
        try write("target/sub/out.js")

        let tracked = try await FileListing.tracked(at: root, exclude: FileExclusion())
        #expect(tracked.files == [".gitignore", "config/kibana.yml", "src/a.ts", "src/b.ts"])
        #expect(!tracked.complete)

        let list = try await FileListing.full(at: root, exclude: FileExclusion())
        #expect(list.files == [
            ".gitignore", "config/kibana.dev.yml", "config/kibana.yml", "src/a.ts", "src/b.ts", "src/new.ts",
        ])
        #expect(list.marks == ["src/a.ts": .modified, "src/new.ts": .untracked])
        #expect(list.isIgnored("config/kibana.dev.yml") && !list.isIgnored("config/kibana.yml"))
        #expect(list.isUnread("target") && list.isIgnored("target"))
        #expect(!list.paths.contains { $0.hasPrefix("node_modules") })

        let read = await FileListing.reading("target", in: root, into: list, exclude: FileExclusion())
        #expect(read.isUnread("target/sub"))
        let deeper = await FileListing.reading("target/sub", in: root, into: read, exclude: FileExclusion())
        #expect(deeper.files.contains("target/sub/out.js"))
        // A fresh listing reads the opened ignored folders again.
        let again = try await FileListing.full(at: root, exclude: FileExclusion(), reading: deeper.readFolders)
        #expect(again.files.contains("target/sub/out.js"))
        let excluded = try await FileListing.full(at: root, exclude: FileExclusion(["node_modules", "*.yml"]))
        #expect(!excluded.files.contains { $0.hasSuffix(".yml") })
    }

    @Test func gitStatusPorcelain() {
        let status = FileStatus.parse(
            " M src/a.ts\0A  src/added.ts\0R  src/new.ts\0src/old.ts\0 D gone.ts\0?? n.ts\0!! target/\0!! x.dev.yml\0"
        )
        #expect(status.marks == [
            "src/a.ts": .modified, "src/added.ts": .added, "src/new.ts": .renamed, "gone.ts": .deleted,
            "n.ts": .untracked,
        ])
        #expect(status.untracked == ["n.ts"])
        #expect(status.ignored == ["target/", "x.dev.yml"])
    }
}

struct FilesTabTests {
    private func agentAndWork() -> TaskLayout {
        let agent = PaneTab(title: "agent", pane: PaneSpec(id: "agent", role: .agent, title: "claude", directory: "/w"))
        let shell = PaneTab(title: "zsh", pane: PaneSpec(id: "shell", role: .shell, title: "zsh", directory: "/w"))
        return TaskLayout(
            root: .split(
                .horizontal, .leaf(PaneGroup(id: "left", tabs: [agent])), .leaf(PaneGroup(id: "right", tabs: [shell])),
                ratio: 0.5
            ),
            focusedGroup: "left"
        )
    }

    @Test func oneFilesTabPerTaskInTheWorkPaneFocusedWhenOpen() {
        var layout = agentAndWork()
        let files = layout.showFiles(directory: "/w")
        #expect(files.role == .files && !files.role.isTerminal)
        #expect(layout.group(ofPane: files.id)?.id == "right")
        #expect(layout.focusedPane?.id == files.id)
        layout.focus(pane: "agent")
        #expect(layout.showFiles(directory: "/w").id == files.id)
        #expect(layout.panes.count { $0.role == .files } == 1)
        #expect(layout.focusedPane?.id == files.id)
        // In the background: opened, not shown.
        var other = agentAndWork()
        let background = other.showFiles(directory: "/w", show: false)
        #expect(other.focusedPane?.id == "agent")
        #expect(other.group("right")?.active?.pane.id == "shell" && other.filesPane?.id == background.id)
    }

    @Test func theTabAndItsFileSurviveTheCache() throws {
        var layout = agentAndWork()
        let files = layout.showFiles(directory: "/w")
        layout.setFile("src/a.ts", paneID: files.id)
        let decoded = try JSONDecoder().decode(TaskLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
        #expect(decoded.filesPane?.path == "src/a.ts")
        let json = try #require(String(data: JSONEncoder().encode(decoded.filesPane), encoding: .utf8))
        #expect(json.contains(#""role":"files""#))
        let old = try JSONDecoder().decode(TaskLayout.self, from: JSONEncoder().encode(agentAndWork()))
        #expect(old.filesPane == nil)
    }

    @Test func theFixtureWorldHasFiles() {
        let list = Fixtures.fileList
        #expect(list.files.count > 30 && list.complete)
        #expect(list.isIgnored("config/kibana.dev.yml"))
        #expect(list.marks["x-pack/platform/plugins/shared/onechat/public/upload_image.ts"] == .modified)
        #expect(Fixtures.fileText("package.json").text?.contains("kibana") == true)
        #expect(Fixtures.fileText("x-pack/platform/plugins/shared/onechat/public/upload_image.ts").text != nil)
        #expect(Fixtures.fileText("nope.ts") == .missing)
        let found = Fixtures.search("credentials")
        #expect(!found.isEmpty)
        #expect(Fixtures.search("Credentials").isEmpty)
    }
}

struct FilesKeyTests {
    private func engine() -> ModeEngine {
        let built = Keymaps.build()
        #expect(built.problems.isEmpty)
        return ModeEngine(keymaps: built.keymaps, scoped: built.scoped)
    }

    private func run(_ engine: inout ModeEngine, _ notation: String) -> [String] {
        // swiftlint:disable:next force_try
        try! KeyNotation.parse(notation).compactMap { stroke in
            if case let .run(command) = engine.handle(stroke) { return command.name }
            return nil
        }
    }

    @Test func gfFindsAFileFromAnywhere() {
        var engine = engine()
        #expect(run(&engine, "gf") == ["files.pick"])
        engine.scope = "diff"
        #expect(run(&engine, "gf") == ["files.pick"])
        #expect(CommandAliases.resolve("files src/a.ts:12") == CommandInvocation(
            name: "tab.files", arguments: ["src/a.ts:12"]
        ))
    }

    @Test func aFocusedFilesTabHasItsOwnKeys() {
        var engine = engine()
        engine.scope = "files"
        let expected: [(String, String)] = [
            ("j", "files.down"), ("k", "files.up"), ("l", "files.open"), ("<CR>", "files.open"), ("h", "files.fold"),
            ("<C-d>", "files.page.down"), ("<C-u>", "files.page.up"), ("gg", "files.top"), ("G", "files.bottom"),
            ("p", "files.pick"), ("/", "files.search"), ("<Tab>", "files.mode"), ("n", "files.match.next"),
            ("N", "files.match.prev"), ("a", "files.ask"), ("y", "files.copy"), ("r", "files.refresh"),
        ]
        for (keys, command) in expected {
            #expect(run(&engine, keys) == [command], "\(keys)")
        }
        // NORMAL's own keys still work around them; ⌃w h/l leave the tab.
        #expect(run(&engine, "gt") == ["tab.next"])
        #expect(run(&engine, "<C-w>h") == ["pane.left"])
        #expect(run(&engine, "gd") == ["tab.diff"])
    }

    @Test func configSetsWhatIsExcludedAndWhereRipgrepIs() {
        let (config, problems) = ConfigLoader
            .decode("[files]\nexclude = [\"node_modules\", \"*.log\"]\n[tools]\nrg = \"/x/rg\"\n")
        #expect(problems.isEmpty)
        #expect(config?.fileExclusion == FileExclusion(["node_modules", "*.log"]))
        #expect(config?.tools.rg == "/x/rg")
        #expect(ConfigLoader.decode(ConfigLoader.defaultSource).config?.fileExclusion == FileExclusion())
    }

    @Test func missingRipgrepIsNotAProblemButABrokenSettingIs() async {
        let missing = await ToolDetection.resolve("rg", configured: "", directories: [], check: { _ in nil })
        #expect(missing.problem?.contains("brew install ripgrep") == true)
        #expect(ToolDetection.excusing(missing, configured: "").problem == nil)
        let broken = await ToolDetection.resolve("rg", configured: "/x/rg", directories: [], check: { _ in nil })
        #expect(ToolDetection.excusing(broken, configured: "/x/rg").problem != nil)
        let git = await ToolDetection.resolve("git", configured: "", directories: [], check: { _ in nil })
        #expect(ToolDetection.excusing(git, configured: "").problem != nil)
    }
}
