import Foundation
@testable import HeedCore
import Testing

/// Repo overrides: removing one from config.toml, and what applies where.
struct OverridesTests {
    @Test func removingAKeyKeepsTheRestAndDropsAnEmptiedTable() throws {
        let source = """
        # heed
        [pilot]
        green = "ask"

        [orgs.elastic]
        # the org's color
        color = "teal"
        reviewers = [
          "copilot",
        ]

        [repos."elastic/docs"]
        green = "auto" # sends on its own
        """
        let document = try TOMLDocument(source)
        let withoutReviewers = document.removing(["orgs", "elastic", "reviewers"])
        #expect(!withoutReviewers.contains("copilot"))
        #expect(withoutReviewers.contains("# the org's color\ncolor = \"teal\""))
        let withoutRepo = try TOMLDocument(document.removing(["repos", "elastic/docs", "green"]))
        #expect(withoutRepo.root.value(at: ["repos", "elastic/docs"]) == nil)
        #expect(!withoutRepo.source.contains("[repos."))
        #expect(withoutRepo.source.contains("[orgs.elastic]"))
        // A key that is not there changes nothing.
        #expect(document.removing(["orgs", "elastic", "merge"]) == source)
    }

    @Test func eachValueSaysWhereItComesFrom() {
        var config = HeedConfig.default
        config.issues.fallback = .all
        config.issues.repos["elastic/docs"] = .involved
        let docs = OverrideScope.repo(Repo(org: "elastic", name: "docs"))
        let other = OverrideScope.repo(Repo(org: "elastic", name: "other"))
        func key(_ id: String) -> OverrideKey { Overrides.keys.first { $0.id == id }! }

        #expect(Overrides.effective(key("issues"), at: docs, in: config) == (.text("involved"), .repo))
        #expect(Overrides.effective(key("issues"), at: other, in: config) == (.text("all"), .default))
        #expect(Overrides.effective(key("color"), at: docs, in: config).source == .default)
        #expect(Set(Overrides.setKeys(at: docs, in: config)) == ["issues"])
        #expect(Overrides.setKeys(at: other, in: config).isEmpty)
        #expect(Overrides.configuredScopes(in: config) == [docs])
        #expect(OverrideValue.list(["a", "b"]).toml == .array([.string("a"), .string("b")]))
    }
}
