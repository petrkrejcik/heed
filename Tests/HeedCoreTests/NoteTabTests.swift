import Foundation
@testable import HeedCore
import Testing

// MARK: - Role + path cache round-trip

struct NoteRoleTests {
    @Test func noteRoleIsNotATerminal() {
        let pane = PaneSpec(role: .note, title: "My note", directory: "/w", path: "/vault/My note.md")
        #expect(!pane.role.isTerminal)
        #expect(pane.path == "/vault/My note.md")
    }

    @Test func noteRoleSurvivesCacheRoundTrip() throws {
        let pane = PaneSpec(id: "n1", role: .note, title: "My note", directory: "/w", path: "/vault/My note.md")
        let encoded = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(PaneSpec.self, from: encoded)
        #expect(decoded == pane)
        #expect(decoded.path == "/vault/My note.md")
        let json = try #require(String(data: JSONEncoder().encode(decoded), encoding: .utf8))
        #expect(json.contains("\"role\":\"note\""))
        // The path key is present (the actual value may have escaped slashes depending on platform).
        #expect(json.contains("\"path\":"))
    }

    @Test func oldCachesWithoutPathDecodeCorrectly() throws {
        let json = #"{"id":"n1","role":"note","title":"My note","directory":"/w"}"#
        let pane = try JSONDecoder().decode(PaneSpec.self, from: Data(json.utf8))
        #expect(pane.role == .note)
        #expect(pane.path == nil)
    }

    @Test func oldCachesWithUnknownRoleFallbackToShell() throws {
        let json = #"{"id":"p1","role":"helper","title":"zsh","directory":"/w"}"#
        let pane = try JSONDecoder().decode(PaneSpec.self, from: Data(json.utf8))
        #expect(pane.role == .shell)
    }

    @Test func pathFieldIsOptionalAndNilByDefault() {
        let pane = PaneSpec(role: .diff, title: "diff", directory: "/w")
        #expect(pane.path == nil)
    }
}

// MARK: - Layout: showNote

struct NoteLayoutTests {
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

    @Test func aNoteTabOpensInTheWorkPaneAndShows() {
        var layout = agentAndWork()
        let note = layout.showNote(path: "/vault/A.md", title: "A", directory: "/w", show: true)
        #expect(note.role == .note)
        #expect(note.path == "/vault/A.md")
        #expect(layout.group(ofPane: note.id)?.id == "right")
        #expect(layout.focusedPane?.id == note.id)
    }

    @Test func showNoteOnAlreadyOpenNoteJustFocusesIt() {
        var layout = agentAndWork()
        let note = layout.showNote(path: "/vault/A.md", title: "A", directory: "/w", show: true)
        layout.focus(pane: "agent")
        let again = layout.showNote(path: "/vault/A.md", title: "A", directory: "/w", show: true)
        #expect(again.id == note.id)
        #expect(layout.panes.count { $0.role == .note } == 1)
        #expect(layout.focusedPane?.id == note.id)
    }

    @Test func twoNotesCanBeOpenAtOnce() {
        var layout = agentAndWork()
        let a = layout.showNote(path: "/vault/A.md", title: "A", directory: "/w", show: true)
        let b = layout.showNote(path: "/vault/B.md", title: "B", directory: "/w", show: true)
        #expect(a.id != b.id)
        #expect(layout.panes.count { $0.role == .note } == 2)
    }

    @Test func showNoteWithShowFalseDoesNotChangeFocus() {
        var layout = agentAndWork()
        layout.showNote(path: "/vault/A.md", title: "A", directory: "/w", show: false)
        #expect(layout.focused?.id == "left")
        #expect(layout.groups[1].active?.title == "zsh")
    }

    @Test func replaceNoteChangesPathAndTitle() {
        var layout = agentAndWork()
        let note = layout.showNote(path: "/vault/A.md", title: "A", directory: "/w", show: true)
        layout.replaceNote(paneID: note.id, path: "/vault/B.md", title: "B")
        #expect(layout.pane(note.id)?.path == "/vault/B.md")
        #expect(layout.pane(note.id)?.title == "B")
        // The old path is gone.
        #expect(layout.notePane(path: "/vault/A.md") == nil)
        #expect(layout.notePane(path: "/vault/B.md")?.id == note.id)
    }

    @Test func noteTabIsSavedWithTheLayout() throws {
        var layout = agentAndWork()
        layout.showNote(path: "/vault/A.md", title: "A", directory: "/w", show: true)
        let decoded = try JSONDecoder().decode(TaskLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
        #expect(decoded.notePane(path: "/vault/A.md")?.title == "A")
    }

    @Test func theTasksFixtureHasANoteTab() throws {
        let layout = try #require(Fixtures.tasks.layouts["t3"])
        let note = try #require(layout.panes.first { $0.role == .note })
        #expect(note.path?.hasSuffix("Fix image upload 403.md") == true)
        #expect(!note.role.isTerminal)
    }
}

// MARK: - NoteIndex

struct NoteIndexTests {
    // Build an index from in-memory fixture data.
    private var entries: [NoteEntry] { Fixtures.noteEntries }

    @Test func fixtureEntriesAreIndexed() {
        #expect(!entries.isEmpty)
        #expect(entries.contains { $0.name == "Fix image upload 403" })
        #expect(entries.contains { $0.name == "Chat attachments" })
    }

    @Test func aliasesAreReadFromFrontmatter() {
        let epic = entries.first { $0.name == "Chat attachments" }
        #expect(epic?.aliases.contains("Chat Attachments") == true)
    }

    @Test func dotFoldersAreSkippedDuringApply() {
        let event = FileEvent(path: "/vault/.obsidian/workspace.md", isDirectory: false, structural: true)
        let result = NoteIndex.applying([event], to: [], vault: "/vault")
        #expect(result.isEmpty)
    }

    @Test func nonMdFilesAreSkippedDuringApply() {
        let event = FileEvent(path: "/vault/image.png", isDirectory: false, structural: true)
        let result = NoteIndex.applying([event], to: entries, vault: Fixtures.vault)
        #expect(result.count == entries.count)
    }

    @Test func extractAliasesBlockList() {
        let md = """
        ---
        aliases:
          - Foo
          - Bar
        ---
        body
        """
        #expect(NoteIndex.extractAliases(from: md) == ["Foo", "Bar"])
    }

    @Test func extractAliasesInlineBracket() {
        let md = """
        ---
        aliases: [Alpha, Beta]
        ---
        """
        #expect(NoteIndex.extractAliases(from: md) == ["Alpha", "Beta"])
    }

    @Test func extractAliasesNone() {
        #expect(NoteIndex.extractAliases(from: "# No frontmatter").isEmpty)
    }
}

// MARK: - WikilinkResolver

struct WikilinkResolverTests {
    private let vault = "/vault"
    private let entries: [NoteEntry] = [
        NoteEntry(
            path: "/vault/Projects/My note.md",
            name: "My note",
            relativePath: "Projects/My note",
            aliases: ["mynote"],
            folder: "Projects"
        ),
        NoteEntry(
            path: "/vault/Archive/My note.md",
            name: "My note",
            relativePath: "Archive/My note",
            aliases: [],
            folder: "Archive"
        ),
        NoteEntry(
            path: "/vault/Projects/Chat attachments.md",
            name: "Chat attachments",
            relativePath: "Projects/Chat attachments",
            aliases: ["Chat Attachments"],
            folder: "Projects"
        ),
    ]

    @Test func exactVaultRelativePathResolves() {
        #expect(WikilinkResolver.resolve("Projects/My note", in: entries) == "/vault/Projects/My note.md")
        #expect(WikilinkResolver.resolve("Projects/My note.md", in: entries) == "/vault/Projects/My note.md")
    }

    @Test func byNameCaseInsensitive() {
        #expect(WikilinkResolver.resolve("my note", in: entries) != nil)
    }

    @Test func shortestPathWinsWhenMultipleNamesMatch() {
        // "My note" matches two entries; "Archive/My note" (15 chars) < "Projects/My note" (16 chars) so Archive wins.
        let result = WikilinkResolver.resolve("My note", in: entries)
        #expect(result == "/vault/Archive/My note.md")
    }

    @Test func aliasResolves() {
        #expect(WikilinkResolver.resolve("Chat Attachments", in: entries) == "/vault/Projects/Chat attachments.md")
        #expect(WikilinkResolver.resolve("chat attachments", in: entries) == "/vault/Projects/Chat attachments.md")
    }

    @Test func headingAndAliasPartsAreStripped() {
        let parsed = WikilinkResolver.Parsed(raw: "My note#section|display text")
        #expect(parsed.target == "My note")
        #expect(parsed.heading == "section")
        #expect(parsed.alias == "display text")
    }

    @Test func unresolvedReturnsNil() {
        #expect(WikilinkResolver.resolve("Nonexistent", in: entries) == nil)
    }

    @Test func emptyTargetReturnsNil() {
        #expect(WikilinkResolver.resolve("", in: entries) == nil)
        #expect(WikilinkResolver.resolve("#heading", in: entries) == nil)
    }
}

// MARK: - FuzzyMatcher

struct FuzzyMatcherTests {
    private let entries: [NoteEntry] = [
        NoteEntry(
            path: "/v/Fix image upload 403.md",
            name: "Fix image upload 403",
            relativePath: "Fix image upload 403",
            folder: ""
        ),
        NoteEntry(
            path: "/v/Chat attachments.md",
            name: "Chat attachments",
            relativePath: "Chat attachments",
            folder: ""
        ),
        NoteEntry(
            path: "/v/Projects/Kibana main.md",
            name: "Kibana main",
            relativePath: "Projects/Kibana main",
            folder: "Projects"
        ),
    ]

    @Test func simpleMatchRanksHigher() {
        let results = FuzzyMatcher.rank(entries: entries, query: "fix")
        #expect(results.first?.entry.name == "Fix image upload 403")
    }

    @Test func noMatchIsExcluded() {
        let results = FuzzyMatcher.rank(entries: entries, query: "zzz")
        #expect(results.isEmpty)
    }

    @Test func taskNoteGetsBonus() {
        let results = FuzzyMatcher.rank(
            entries: entries, query: "ch",
            taskNotePath: "/v/Chat attachments.md"
        )
        #expect(results.first?.entry.path == "/v/Chat attachments.md")
    }

    @Test func isMatchSubsequence() {
        #expect(FuzzyMatcher.isMatch(query: "fiu", in: "Fix image upload 403"))
        #expect(!FuzzyMatcher.isMatch(query: "xyz", in: "Fix image upload 403"))
        #expect(FuzzyMatcher.isMatch(query: "", in: "anything"))
    }
}

// MARK: - NotePicker

struct NotePickerTests {
    private let entries: [NoteEntry] = [
        NoteEntry(
            path: "/v/task.md", name: "Task note", relativePath: "task", folder: "",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 300)
        ),
        NoteEntry(
            path: "/v/epic.md", name: "Epic note", relativePath: "epic", folder: "",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 200)
        ),
        NoteEntry(
            path: "/v/other.md", name: "Other note", relativePath: "other", folder: "",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 100)
        ),
    ]

    private func picker(query: String = "") -> NotePicker {
        NotePicker(allEntries: entries, taskNotePath: "/v/task.md", epicNotePath: "/v/epic.md", query: query)
    }

    @Test func emptyQueryShowsTaskNoteFirst() {
        let p = picker()
        let rows = p.rows
        #expect(rows.first?.path == "/v/task.md")
        #expect(rows.dropFirst().first?.path == "/v/epic.md")
        // The rest by modified time descending.
        #expect(rows.dropFirst(2).first?.path == "/v/other.md")
    }

    @Test func queryFiltersAndRanks() {
        let p = picker(query: "epic")
        let rows = p.rows
        #expect(rows.first?.name == "Epic note")
    }

    @Test func escapeCloses() {
        var p = picker()
        #expect(p.handle(.escape) == .cancel)
    }

    @Test func returnOpensWithShow() {
        var p = picker()
        if case let .open(entry, show) = p.handle(KeyStroke("CR")) {
            #expect(entry.path == "/v/task.md")
            #expect(show)
        } else {
            Issue.record("expected .open")
        }
    }

    @Test func commandReturnOpensWithoutShow() {
        var p = picker()
        if case let .open(_, show) = p.handle(KeyStroke("CR", .command)) {
            #expect(!show)
        } else {
            Issue.record("expected .open")
        }
    }

    @Test func jkMoveTheCursor() {
        var p = picker()
        #expect(p.handle(KeyStroke("j")) == .handled)
        #expect(p.cursor == 1)
        #expect(p.handle(KeyStroke("k")) == .handled)
        #expect(p.cursor == 0)
    }

    @Test func controlNPMoveTheCursor() {
        var p = picker()
        _ = p.handle(KeyStroke("n", .control))
        #expect(p.cursor == 1)
        _ = p.handle(KeyStroke("p", .control))
        #expect(p.cursor == 0)
    }

    @Test func cursorDoesNotGoOutOfBounds() {
        var p = picker()
        for _ in 0 ..< 10 {
            _ = p.handle(KeyStroke("j"))
        }
        #expect(p.cursor == entries.count - 1)
        for _ in 0 ..< 10 {
            _ = p.handle(KeyStroke("k"))
        }
        #expect(p.cursor == 0)
    }

    @Test func typingEditsTheQuery() {
        var p = picker()
        _ = p.handle(KeyStroke("e"))
        _ = p.handle(KeyStroke("p"))
        #expect(p.query == "ep")
    }

    @Test func backspaceRemovesLastChar() {
        var p = picker(query: "epi")
        _ = p.handle(KeyStroke("BS"))
        #expect(p.query == "ep")
    }

    @Test func controlWDropsLastWord() {
        var p = picker(query: "chat attachments")
        _ = p.handle(KeyStroke("w", .control))
        #expect(p.query == "chat")
    }
}

// MARK: - NewTabPicker: .note kind

struct NewTabPickerNoteTests {
    @Test func nOpensNote() {
        let picker = NewTabPicker(last: .terminal)
        #expect(picker.handle(KeyStroke("n")) == .open(.note))
    }

    @Test func noteKindHasKeyN() {
        #expect(NewTabPicker.Kind.note.key == "n")
        #expect(NewTabPicker.Kind.note.label == "Note")
    }
}

// MARK: - Commands and keys

struct NoteCommandTests {
    @Test func noteCommandsExist() {
        for name in [
            "note.pick",
            "note.obsidian",
            "note.copy",
            "note.reload",
            "note.scroll.down",
            "note.scroll.up",
            "note.scroll.top",
            "note.scroll.bottom",
        ] {
            #expect(Commands.spec(name) != nil, "Command \(name) is missing")
        }
    }

    @Test func gNBindsNotePickCommand() {
        let built = Keymaps.build()
        #expect(built.problems.isEmpty)
        var engine = ModeEngine(keymaps: built.keymaps, scoped: built.scoped)
        // swiftlint:disable:next force_try
        let strokes = try! KeyNotation.parse("gN")
        let outcomes = strokes.compactMap { stroke -> String? in
            if case let .run(cmd) = engine.handle(stroke) { return cmd.name }
            return nil
        }
        #expect(outcomes == ["note.pick"])
    }

    @Test func noteScopeKeysWork() {
        let built = Keymaps.build()
        #expect(built.problems.isEmpty)
        var engine = ModeEngine(keymaps: built.keymaps, scoped: built.scoped)
        engine.scope = "note"
        func run(_ notation: String) -> [String] {
            // swiftlint:disable:next force_try
            (try! KeyNotation.parse(notation)).compactMap { stroke in
                if case let .run(cmd) = engine.handle(stroke) { return cmd.name }
                return nil
            }
        }
        #expect(run("j") == ["note.scroll.down"])
        #expect(run("k") == ["note.scroll.up"])
        #expect(run("e") == ["note.obsidian"])
        #expect(run("y") == ["note.copy"])
        #expect(run("r") == ["note.reload"])
        // NORMAL's own keys still work around it.
        #expect(run("l") == ["pane.right"])
        #expect(run("gt") == ["tab.next"])
    }

    @Test func noteAliasResolvesToNotePick() {
        let resolved = CommandAliases.resolve("note chat")
        #expect(resolved.name == "note.pick")
        #expect(resolved.arguments == ["chat"])
    }
}
