import Foundation
@testable import HeedCore
import Testing

struct TagColorsTests {
    @Test func readsThePluginsDataAndTurnsAnIndexIntoItsHue() throws {
        let data = Data(#"{"assigned": {"heed-fork": 0, "bug-bash": 2, "knowledge-documents-viewer": 5}}"#.utf8)
        let colors = try #require(TagColors.parse(data))
        #expect(colors.hue(of: "heed-fork") == 10)
        #expect(colors.hue(of: "bug-bash") == 55)
        #expect(colors.hue(of: "knowledge-documents-viewer") == 215)
        // As the plugin keys them: no `#`, any case.
        #expect(colors.hue(of: "#Bug-Bash") == 55)
        // Not coloured by Obsidian yet, or an index the plugin has no hue for: none.
        #expect(colors.hue(of: "new-tag") == nil)
        #expect(TagColors(assigned: ["odd": 9]).hue(of: "odd") == nil)
    }

    @Test func anotherShapeIsNoColours() {
        #expect(TagColors.parse(Data("not json".utf8)) == nil)
        #expect(TagColors.parse(Data("{}".utf8)) == TagColors.none)
    }

    @Test func readsTheFileInTheVaultAndKnowsItsEvents() async throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("heed-tags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vault) }
        #expect(await TagColors.read(vault: vault.path) == .none)
        let file = vault.appendingPathComponent(TagColors.file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"assigned": {"heed-fork": 3}}"#.utf8).write(to: file)
        #expect(await TagColors.read(vault: vault.path) == TagColors(assigned: ["heed-fork": 3]))
        #expect(TagColors.isFile(file.path, vault: vault.path))
        #expect(TagColors.isFile(file.path, vault: vault.path + "/"))
        #expect(!TagColors.isFile(vault.appendingPathComponent(".obsidian/workspace.json").path, vault: vault.path))
    }

    @Test func aCacheFromBeforeTagsLoadsWithNone() throws {
        var json = try #require(JSONSerialization
            .jsonObject(with: JSONEncoder().encode(Fixtures.tasks)) as? [String: Any])
        json["tagColors"] = nil
        var tasks = try #require(json["tasks"] as? [[String: Any]])
        for index in tasks.indices {
            tasks[index]["noteTags"] = nil
        }
        json["tasks"] = tasks
        let old = try JSONDecoder().decode(Domain.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.tagColors == .none)
        #expect(old.tasks.allSatisfy { $0.tags.isEmpty })
        #expect(old.tasks.map(\.id) == Fixtures.tasks.tasks.map(\.id))
        // And what is cached comes back.
        let cached = try JSONDecoder().decode(Domain.self, from: JSONEncoder().encode(Fixtures.tasks))
        #expect(cached.tagColors == Fixtures.tasks.tagColors)
        #expect(cached.tasks.map(\.tags) == Fixtures.tasks.tasks.map(\.tags))
    }

    @Test func pksTagsReachTheTaskAndAnOlderPkSendsNone() throws {
        let pk = PkTask(id: "t", title: "T", status: "In Progress", tags: ["heed-fork"])
        #expect(WorkTask(pk, keeping: nil)?.tags == ["heed-fork"])
        let older = try JSONDecoder().decode(
            PkTask.self,
            from: Data(#"{"id": "t", "title": "T", "status": "To Do", "pinned": false, "running": false}"#.utf8)
        )
        #expect(older.tags == nil)
        #expect(WorkTask(older, keeping: nil)?.tags == [])
    }
}
