import Foundation

/// What the fixture panes show in screenshots (shot mode draws these instead of starting a shell), keyed by pane id.
/// Markup: `{dim}`, `{bold}`, `{green}`, `{blue}`, `{amber}`, `{red}`, `{violet}` start a style, `{/}` ends it.
public extension Fixtures {
    /// Fixture pages that failed to load, keyed by pane id, with the reason the page shows.
    static let pageFailures: [String: String] = [
        "t3-page": "Could not connect to the server.",
    ]

    static let transcripts: [String: String] = [
        "t2-agent": """
        {bold}claude{/} {dim}· 299433-fix-image-upload-403{/}

        {bold}>{/} Fix the 403 on image upload behind
          a proxy. Read the task note first.

        {violet}●{/} The upload skips the base path, so
          the proxy rejects it. Fixing that.

        {green}●{/} {bold}Update{/}(upload_image.ts)
          {dim}⎿ 4 additions, 2 removals{/}

        {green}●{/} {bold}Write{/}(upload_image.test.ts)
          {dim}⎿ Wrote 18 lines{/}

        {blue}●{/} {bold}Bash{/}(yarn test:jest upload_image)
          {dim}⎿ 12 passed, 0 failed so far{/}

        {amber}✻ Running tests… (2m · esc){/}
        """,
        "t2-shell": """
        {green}you@mac{/} {blue}299433-fix-image-upload-403{/} % git status -s
         M x-pack/…/public/upload_image.ts
        ?? x-pack/…/public/upload_image.test.ts
        {green}you@mac{/} {blue}299433-fix-image-upload-403{/} % ▌
        """,
        "t2-agent2": """
        {bold}>{/} Answer the review comments on
          #299455.

        {green}●{/} Both threads answered. The second
          needs a proxy test; noted in the task.
        """,
        "t2-jest": """
        {dim}yarn test:jest --watch{/}
          Tests: 12 passed, 12 total
        {dim}Watching for file changes{/}
        """,
        "t5-agent": """
        {bold}claude{/} {dim}· kibana{/}

        {violet}●{/} Two questions before I dig into
          SSE batching:

          {violet}1.{/} Batch by time (50ms) or by
             size (8 events)?
          {violet}2.{/} Measure in the browser or in
             the server logs?

        {dim}Enter to select · ↑/↓ to navigate · Esc to cancel{/}
        """,
        "t3-agent": """
        {bold}claude{/} {dim}· review-299044-timeline-freeze{/}

        {green}●{/} Review done. The freeze comes from
          re-rendering every round; memoizing
          the round list fixes it. Notes are in
          the task.
        """,
        "t1-kibana": """
        {dim}[2026-10-26T09:12:04] [info][status] Kibana is now available{/}
        {dim}server    log   [09:12:04.311] http server running at{/} http://localhost:5601
        """,
    ]

    /// A pane without a transcript: a quiet prompt in its directory.
    static func prompt(for pane: PaneSpec) -> String {
        let folder = (pane.directory as NSString).lastPathComponent
        return "{green}you@mac{/} {blue}\(folder){/} % ▌"
    }
}
