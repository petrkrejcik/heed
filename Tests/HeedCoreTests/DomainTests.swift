import Foundation
@testable import HeedCore
import Testing

struct DomainCacheTests {
    @Test func storeRoundTripsThroughItsCacheFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("heed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = DomainStore(file: file, writeDelay: .zero)
        let fixture = Fixtures.tasks
        await store.apply(fixture.tasks.map { .taskUpserted($0) })
        await store.apply(fixture.layouts.map { .layoutChanged(task: $0.key, $0.value) })
        await store.apply(fixture.agents.map { .agentChanged(pane: $0.key, $0.value) })
        await store.flush()
        let loaded = await DomainStore.load(from: file)
        #expect(loaded.tasks == fixture.tasks)
        #expect(loaded.layouts == fixture.layouts)
        #expect(loaded.agents == fixture.agents)
        #expect(await DomainStore.load(from: file.appendingPathExtension("missing")) == .empty)
    }

    /// Fields this build no longer has, and the pilot's helper tabs, from caches written before they were cut.
    @Test func unknownFieldsAreSkipped() throws {
        var json = try #require(JSONSerialization
            .jsonObject(with: JSONEncoder().encode(Fixtures.tasks)) as? [String: Any])
        json["feedback"] = [:] as [String: Any]
        json["runs"] = [] as [Any]
        var tasks = try #require(json["tasks"] as? [[String: Any]])
        tasks[0]["someFieldPkAddsLater"] = "x"
        json["tasks"] = tasks
        let helper = PaneSpec(id: "h", role: .shell, title: "get it green", directory: "/tmp")
        var pane = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(helper)) as? [String: Any])
        pane["role"] = "helper"
        let data = try JSONSerialization.data(withJSONObject: json)
        let loaded = try JSONDecoder().decode(Domain.self, from: data)
        #expect(loaded.tasks.map(\.id) == Fixtures.tasks.tasks.map(\.id))
        #expect(loaded.pullDetails.keys.sorted() == Fixtures.tasks.pullDetails.keys.sorted())
        let decoded = try JSONDecoder().decode(PaneSpec.self, from: JSONSerialization.data(withJSONObject: pane))
        #expect(decoded.role == .shell)
    }

    @Test func aPinnedCommandPaneKeepsItsRole() throws {
        let spec = PaneSpec(id: "c", role: .command, title: "jest", directory: "/w", command: "yarn test:jest")
        let decoded = try JSONDecoder().decode(PaneSpec.self, from: JSONEncoder().encode(spec))
        #expect(decoded.role == .command)
        #expect(decoded.command == "yarn test:jest")
    }
}

struct ProcessRunnerTests {
    @Test func runnerTimesOut() async {
        await #expect(throws: ProcessError.self) {
            _ = try await ProcessRunner.run("sleep", ["5"], timeout: .milliseconds(100))
        }
    }
}
