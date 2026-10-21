import Foundation

/// What a browser pane's address field makes of what you typed: a URL as typed, a bare host (`github.com/o/r`,
/// `localhost:3000`) as a URL, anything else a web search.
public enum BrowserAddress {
    static let schemes: Set<String> = ["http", "https", "file", "about"]

    public static func url(from text: String) -> String? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if let scheme = URL(string: typed)?.scheme?.lowercased(), schemes.contains(scheme) { return typed }
        if !typed.contains(" "), let name = hostName(typed) {
            let local = name == "localhost" || name == "127.0.0.1"
            return (local ? "http://" : "https://") + typed
        }
        var search = URLComponents(string: "https://www.google.com/search")
        search?.queryItems = [URLQueryItem(name: "q", value: typed)]
        return search?.url?.absoluteString
    }

    /// The host of `github.com/o/r` or `localhost:3000`, when the text looks like it starts with one.
    static func hostName(_ text: String) -> String? {
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let name = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        let dotted = name.contains(".") && !name.hasPrefix(".") && !name.hasSuffix(".")
        return name == "localhost" || dotted ? name : nil
    }

    /// What a browser tab is called: the page's title, else its host, short enough for the tab strip.
    public static func tabTitle(title: String, url: String?) -> String {
        let name = title.isEmpty ? url.flatMap { URL(string: $0)?.host() } ?? "new page" : title
        return name.count > 28 ? name.prefix(27) + "…" : name
    }
}
