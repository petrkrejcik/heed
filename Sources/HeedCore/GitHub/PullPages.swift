/// The PR panel's pages: a task's PR as GitHub shows it, one web page per PR. The few shown last stay loaded, so
/// showing one again is instant and keeps its place (scrolled, on Files changed); older ones are closed. Not
/// persisted: the panel is temporary.
public struct PullPages: Equatable, Sendable {
    public static let kept = 4

    /// Newest first.
    public private(set) var recent: [PullRef] = []

    public init() {}

    /// `ref` is shown: it moves to the front. Returns the pages to close, those that fell off the end.
    public mutating func show(_ ref: PullRef) -> [PullRef] {
        recent.removeAll { $0 == ref }
        recent.insert(ref, at: 0)
        guard recent.count > Self.kept else { return [] }
        let dropped = Array(recent[Self.kept...])
        recent.removeLast(recent.count - Self.kept)
        return dropped
    }

    /// The page's id among the web views; never a pane id of a task's layout (those are UUIDs).
    public static func paneID(_ ref: PullRef) -> String { "pr-page:\(ref.description)" }

    public static func isPaneID(_ id: String) -> Bool { id.hasPrefix("pr-page:") }

    /// What the web view is made from: a page pane at the PR's address.
    public static func pane(_ ref: PullRef) -> PaneSpec {
        PaneSpec(
            id: paneID(ref), role: .browser, title: "\(ref.repo.name) #\(ref.number)", directory: "", url: ref.url
        )
    }
}
