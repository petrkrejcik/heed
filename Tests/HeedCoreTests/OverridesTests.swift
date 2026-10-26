import Foundation
@testable import HeedCore
import Testing

/// Org and repo overrides: removing one from config.toml, and what applies where.
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
        config.orgColors["elastic"] = "teal"
        config.issues.orgs["elastic"] = .all
        config.issues.repos["elastic/docs"] = .involved
        let docs = OverrideScope.repo(Repo(org: "elastic", name: "docs"))
        func key(_ id: String) -> OverrideKey { Overrides.keys.first { $0.id == id }! }

        #expect(Overrides.effective(key("issues"), at: docs, in: config) == (.text("involved"), .repo))
        #expect(Overrides.effective(key("issues"), at: .org("elastic"), in: config) == (.text("all"), .org))
        #expect(Overrides.effective(key("color"), at: .org("elastic"), in: config) == (.text("teal"), .org))
        #expect(Overrides.effective(key("color"), at: .org("nullean"), in: config).source == .default)
        #expect(Set(Overrides.setKeys(at: docs, in: config)) == ["issues"])
        #expect(Set(Overrides.setKeys(at: .org("elastic"), in: config)) == ["color", "issues"])
        #expect(Overrides.configuredScopes(in: config) == [.org("elastic"), docs])
        #expect(OverrideValue.list(["a", "b"]).toml == .array([.string("a"), .string("b")]))
    }
}
