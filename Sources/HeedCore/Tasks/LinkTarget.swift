import Foundation

/// Where a link opened in Heed becomes a page: in the task it came from (its terminal, its PR card, its inspector),
/// else in Kibana main, the pinned task in the main checkout. Done and Dropped tasks take no pages.
public enum LinkTarget {
    public static func task(from source: String?, in tasks: [WorkTask], mainCheckout: String = Kibana.mainCheckout)
        -> String?
    {
        let open = tasks.filter { !$0.status.endsTask }
        if let source, open.contains(where: { $0.id == source }) { return source }
        return open.first { $0.pinned && ($0.worktree ?? mainCheckout) == mainCheckout }?.id
    }

    /// Links Heed opens as pages; anything else (`mailto:`, a file path) goes to the app macOS picks for it.
    public static func opensAsPage(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
