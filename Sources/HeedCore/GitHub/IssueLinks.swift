import Foundation

/// An issue, by repo and number.
public struct IssueRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public var repo: Repo
    public var number: Int

    public init(repo: Repo, number: Int) {
        self.repo = repo
        self.number = number
    }

    /// `https://github.com/org/name/issues/123` (with or without a trailing path).
    public init?(url: String) {
        let parts = url.split(separator: "/").map(String.init)
        guard let issues = parts.firstIndex(of: "issues"), issues >= 2, issues + 1 < parts.count,
              let number = Int(parts[issues + 1].prefix { $0.isNumber })
        else { return nil }
        self.init(repo: Repo(org: parts[issues - 2], name: parts[issues - 1]), number: number)
    }

    public var description: String { "\(repo.slug)#\(number)" }
    public var url: String { "https://github.com/\(repo.slug)/issues/\(number)" }
}

/// What heed knows of a linked issue beyond its number: fetched when a task shows it.
public struct IssueInfo: Hashable, Sendable {
    public var title: String
    public var closed: Bool
    public var body: String
    public var labels: [String]
    public var author: String?
    public var updatedAt: Date

    public init(
        title: String, closed: Bool, body: String = "", labels: [String] = [], author: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.title = title
        self.closed = closed
        self.body = body
        self.labels = labels
        self.author = author
        self.updatedAt = updatedAt
    }
}

/// One thing a task links to on GitHub: its PR, its issue, or the repo. The inspector lists them, `gB` opens them.
public enum TaskLink: Hashable, Sendable {
    case pull(PullRef)
    case issue(IssueRef)
    case repo(Repo)

    public var url: String {
        switch self {
        case let .pull(ref): ref.url
        case let .issue(ref): ref.url
        case let .repo(repo): "https://github.com/\(repo.slug)"
        }
    }

    public var label: String {
        switch self {
        case let .pull(ref): "\(ref.repo.name) #\(ref.number)"
        case let .issue(ref): "\(ref.repo.name) #\(ref.number)"
        case let .repo(repo): repo.slug
        }
    }
}

public enum IssueLinks {
    /// The compare page that opens a PR for a pushed branch.
    public static func compareURL(repo: Repo, branch: String) -> String {
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        return "https://github.com/\(repo.slug)/compare/\(encoded)?expand=1"
    }
}

/// `gB` (or `gR`) when there is more than one place to go: the links, a cursor, and keys to pick one or all.
public struct LinkPicker: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case handled, cancel
        case open([TaskLink])
    }

    public let title: String
    public let links: [TaskLink]
    public private(set) var cursor = 0

    public init(title: String, links: [TaskLink]) {
        self.title = title
        self.links = links
    }

    /// `j` `k` (`⌃n` `⌃p`, arrows) move, `↩` opens the one under the cursor, `1`–`9` open that one, `a` opens all,
    /// `⎋` (or `q`) closes.
    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        switch stroke {
        case KeyStroke("j"), KeyStroke("n", .control), KeyStroke("Down"):
            cursor = min(cursor + 1, links.count - 1)
        case KeyStroke("k"), KeyStroke("p", .control), KeyStroke("Up"):
            cursor = max(cursor - 1, 0)
        case KeyStroke("CR"):
            return links.indices.contains(cursor) ? .open([links[cursor]]) : .cancel
        case KeyStroke("a"):
            return .open(links)
        case .escape, KeyStroke("q"):
            return .cancel
        default:
            if let number = Int(stroke.key), (1 ... 9).contains(number), stroke.modifiers.isEmpty {
                return links.indices.contains(number - 1) ? .open([links[number - 1]]) : .handled
            }
        }
        return .handled
    }
}
