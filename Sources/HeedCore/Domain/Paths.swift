import Foundation

public enum Paths {
    public static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// `/Users/me/code/x` as `~/code/x`, for display.
    public static func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The home folder: the real one, or the fake world's in fixtures and screenshots.
    public nonisolated(unsafe) static var home = NSHomeDirectory()
}

/// The fork works on Kibana only, so its repo is fixed. Its main checkout is pk's (`paths.get`, which honours
/// `PK_KIBANA_MAIN`).
public enum Kibana {
    public static let repo = Repo(org: "elastic", name: "kibana")
    /// Set once pk said where the main checkout is.
    public nonisolated(unsafe) static var configuredMain: String?
    /// Where tasks without a worktree run their agents: pk's answer, else `~/www/kibana` until it arrives.
    public static var mainCheckout: String { configuredMain ?? Paths.home + "/www/kibana" }
}
