import Foundation

/// The Diff tab's file list as a folder tree, as VS Code draws it: folders first, then files, each by name; a folder
/// whose only child is a folder shares its row (`x-pack/platform/plugins`), so deep paths do not stair-step.
public struct DiffTree: Hashable, Sendable {
    public indirect enum Node: Hashable, Sendable {
        case folder(Folder)
        case file(FileDiff)
    }

    public struct Folder: Hashable, Sendable {
        /// The folder's full path: its id, and what `collapsed` holds.
        public var path: String
        /// What its row says: one name, or several joined with `/` for a chain of single folders.
        public var name: String
        public var children: [Node]
    }

    /// One row of the list as drawn.
    public struct Row: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            case folder(name: String, open: Bool)
            case file(FileDiff)
        }

        /// A folder's path, or `file:` and a file's path.
        public var id: String
        public var depth: Int
        public var kind: Kind
    }

    public let roots: [Node]

    public init(_ files: [FileDiff]) {
        roots = Self.build(files.map { ($0.path.split(separator: "/").map(String.init), $0) }, prefix: "")
    }

    /// Every file in the order the tree lists them.
    public var files: [FileDiff] { Self.files(roots) }

    /// The rows to draw: what is inside a closed folder is left out.
    public func rows(collapsed: Set<String>) -> [Row] {
        var rows: [Row] = []
        func walk(_ nodes: [Node], depth: Int) {
            for node in nodes {
                switch node {
                case let .folder(folder):
                    let open = !collapsed.contains(folder.path)
                    rows.append(Row(id: folder.path, depth: depth, kind: .folder(name: folder.name, open: open)))
                    if open { walk(folder.children, depth: depth + 1) }
                case let .file(file):
                    rows.append(Row(id: "file:\(file.path)", depth: depth, kind: .file(file)))
                }
            }
        }
        walk(roots, depth: 0)
        return rows
    }

    /// The paths of the folder rows `path` sits under, outermost first.
    public static func folders(containing path: String, in tree: DiffTree) -> [String] {
        func search(_ nodes: [Node], trail: [String]) -> [String]? {
            for node in nodes {
                switch node {
                case let .file(file) where file.path == path: return trail
                case .file: continue
                case let .folder(folder):
                    guard path.hasPrefix(folder.path + "/") else { continue }
                    if let found = search(folder.children, trail: trail + [folder.path]) { return found }
                }
            }
            return nil
        }
        return search(tree.roots, trail: []) ?? []
    }

    private static func files(_ nodes: [Node]) -> [FileDiff] {
        nodes.flatMap { node -> [FileDiff] in
            switch node {
            case let .folder(folder): files(folder.children)
            case let .file(file): [file]
            }
        }
    }

    /// `entries`: each file's remaining path components under `prefix`.
    private static func build(_ entries: [([String], FileDiff)], prefix: String) -> [Node] {
        var folders: [String: [([String], FileDiff)]] = [:]
        var leaves: [FileDiff] = []
        for (components, file) in entries {
            if components.count <= 1 {
                leaves.append(file)
            } else {
                folders[components[0], default: []].append((Array(components.dropFirst()), file))
            }
        }
        let order = { (lhs: String, rhs: String) in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        var nodes: [Node] = []
        for name in folders.keys.sorted(by: order) {
            var path = prefix + name
            var label = name
            var inside = folders[name] ?? []
            // One folder and nothing else inside: it joins this row.
            while inside.allSatisfy({ $0.0.count > 1 }), let first = inside.first?.0.first,
                  inside.allSatisfy({ $0.0.first == first })
            {
                path += "/" + first
                label += "/" + first
                inside = inside.map { (Array($0.0.dropFirst()), $0.1) }
            }
            nodes.append(.folder(Folder(path: path, name: label, children: build(inside, prefix: path + "/"))))
        }
        let names = { (file: FileDiff) in (file.path as NSString).lastPathComponent }
        nodes += leaves.sorted { order(names($0), names($1)) }.map(Node.file)
        return nodes
    }
}
