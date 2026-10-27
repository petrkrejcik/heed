import Foundation

/// A task's Kibana page, which Heed opens by itself: once per Kibana start, in the background.
public enum KibanaPage {
    public enum Action: Hashable, Sendable {
        /// No page on the task's Kibana yet: a new tab at its URL, not shown.
        case open(url: String)
        /// Kibana restarted under a page already on it: that page reloads.
        case reload(pane: String)
    }

    /// Tasks whose Kibana these changes start: running now and not before. Probes that find it still running say
    /// nothing, so a start gives one page, not one per probe.
    public static func started(by changes: [DomainChange], in tasks: [WorkTask]) -> [String] {
        let before = Dictionary(tasks.map { ($0.id, $0.running) }, uniquingKeysWith: { first, _ in first })
        var started: [String] = []
        for case let .taskUpserted(task) in changes where task.running && before[task.id] == false {
            if !started.contains(task.id) { started.append(task.id) }
        }
        return started
    }

    /// What a start does for a task: reload the first page on its Kibana's host, else open one. Nothing without a URL.
    public static func action(url: String?, layout: TaskLayout?) -> Action? {
        guard let url, let kibana = origin(url) else { return nil }
        let pages = layout?.panes.filter { $0.role == .browser } ?? []
        if let page = pages.first(where: { $0.url.flatMap(origin) == kibana }) { return .reload(pane: page.id) }
        return .open(url: url)
    }

    /// `http://localhost:5602` from any address on that host: scheme, host and port, the port filled in.
    static func origin(_ address: String) -> String? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
        else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}
