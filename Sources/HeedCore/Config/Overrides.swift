/// What a repo (`[repos."org/name"]`) can override, read from the parsed config: which keys it sets, and for any key
/// the value that applies and where it comes from. Settings' Repos page is built on this.
public enum OverrideScope: Hashable, Sendable {
    case repo(Repo)

    /// The table in config.toml.
    public var path: [String] {
        switch self {
        case let .repo(repo): ["repos", repo.slug]
        }
    }

    public var title: String {
        switch self {
        case let .repo(repo): repo.slug
        }
    }
}

/// Where a value comes from: heed's default, or the repo.
public enum OverrideSource: String, Sendable {
    case `default`, repo
}

/// A value of an override, as config.toml holds it.
public enum OverrideValue: Hashable, Sendable {
    case bool(Bool)
    case text(String)
    case integer(Int)
    case list([String])

    public var toml: TOMLValue {
        switch self {
        case let .bool(value): .bool(value)
        case let .text(value): .string(value)
        case let .integer(value): .integer(value)
        case let .list(values): .array(values.map { .string($0) })
        }
    }

    public var display: String {
        switch self {
        case let .bool(value): value ? "on" : "off"
        case let .text(value): value.isEmpty ? "none" : value
        case let .integer(value): "\(value)"
        case let .list(values): values.isEmpty ? "none" : values.joined(separator: ", ")
        }
    }
}

/// One key a repo can set.
public struct OverrideKey: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case bool
        case choice([String])
        case integer(ClosedRange<Int>)
        case list
        case text
        /// One of the palette's names (the app draws the swatches).
        case color
    }

    /// The key in config.toml.
    public let id: String
    public let label: String
    public let detail: String
    public let kind: Kind
    /// The group the page lists it under.
    public var group: String { Overrides.groups.first { $0.keys.contains(id) }?.title ?? "Other" }
    let read: @Sendable (HeedConfig, OverrideScope) -> OverrideValue?
    let fallback: @Sendable (HeedConfig) -> OverrideValue
}

public enum Overrides {
    /// Every key, in the order the page lists them.
    public static let keys: [OverrideKey] = [
        OverrideKey(
            id: "color", label: "Color", detail: "The chip color; unset, one picked from the org's name.",
            kind: .color,
            read: { config, scope in
                switch scope {
                case let .repo(repo): config.repos[repo.slug]?.color.map(OverrideValue.text)
                }
            },
            fallback: { _ in .text("by name") }
        ),
        OverrideKey(
            id: "issues", label: "Issues", detail: "All open issues, or only those assigned to you or mentioning you.",
            kind: .choice(["all", "involved"]),
            read: { config, scope in
                switch scope {
                case let .repo(repo): config.issues.repos[repo.slug].map { .text($0.rawValue) }
                }
            },
            fallback: { .text($0.issues.fallback.rawValue) }
        ),
    ]

    /// The groups the page lists keys under, in order.
    public static let groups: [(title: String, keys: [String])] = [
        ("General", ["color", "issues"]),
    ]

    /// The keys that apply at a scope, in group order.
    public static func keys(for _: OverrideScope) -> [OverrideKey] {
        let order = groups.flatMap(\.keys)
        return keys.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    /// The value set at exactly this scope, if any.
    public static func value(_ key: OverrideKey, at scope: OverrideScope, in config: HeedConfig) -> OverrideValue? {
        key.read(config, scope)
    }

    /// The value that applies at a scope, and where it comes from: the repo, else the default.
    public static func effective(
        _ key: OverrideKey, at scope: OverrideScope, in config: HeedConfig
    ) -> (value: OverrideValue, source: OverrideSource) {
        if let own = key.read(config, scope) { return (own, .repo) }
        return (key.fallback(config), .default)
    }

    /// The keys set at a scope (its own overrides), plus the repo's tasks.
    public static func setKeys(at scope: OverrideScope, in config: HeedConfig) -> [String] {
        var result = keys(for: scope).filter { $0.read(config, scope) != nil }.map(\.id)
        if case let .repo(repo) = scope, !(config.repos[repo.slug]?.tasks.isEmpty ?? true) { result.append("tasks") }
        return result
    }

    /// Repos named in config.toml, whether or not they are cloned here.
    public static func configuredScopes(in config: HeedConfig) -> [OverrideScope] {
        let repos = Set(config.repos.keys).union(config.issues.repos.keys)
        return repos.sorted().compactMap { slug in
            let parts = slug.split(separator: "/")
            return parts.count == 2 ? .repo(Repo(org: String(parts[0]), name: String(parts[1]))) : nil
        }
    }
}
