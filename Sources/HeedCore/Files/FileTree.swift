import Foundation

/// The Files tab's tree, drawn as VS Code's explorer (folders first, then files, each by name; a folder whose only
/// child is a folder shares its row) but built lazily: only open folders are read out of the list, each a slice of
/// its sorted paths, so a checkout of 134k files costs what is on screen.
public enum FileTree {
    public struct Row: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            /// `unread`: an ignored folder whose contents are read from disk once it is opened.
            case folder(open: Bool, unread: Bool)
            case file(FileList.Mark?)
        }

        /// `d:` and a folder's path, or `f:` and a file's.
        public var id: String
        /// The folder (the last of a chain) or the file.
        public var path: String
        /// What the row says: a name, or a chain of single folders joined with `/`.
        public var name: String
        public var depth: Int
        public var kind: Kind
        /// Ignored by git: greyed.
        public var ignored: Bool
        /// A folder with a changed file in it.
        public var changed: Bool

        public var isFolder: Bool {
            if case .folder = kind { return true }
            return false
        }

        public static func id(file path: String) -> String { "f:\(path)" }
        public static func id(folder path: String) -> String { "d:\(path)" }
    }

    /// The rows to draw: the root's, and inside every open folder its own.
    public static func rows(_ list: FileList, open: Set<String>) -> [Row] {
        var rows: [Row] = []
        func walk(_ folder: String, depth: Int) {
            let (folders, files) = children(of: folder, in: list)
            for child in folders {
                let (path, name) = chain(child, in: list)
                let isOpen = open.contains(path)
                rows.append(Row(
                    id: Row.id(folder: path), path: path, name: name, depth: depth,
                    kind: .folder(open: isOpen, unread: list.isUnread(path)), ignored: list.isIgnored(path),
                    changed: list.changedFolders.contains(path)
                ))
                if isOpen { walk(path, depth: depth + 1) }
            }
            for file in files {
                rows.append(Row(
                    id: Row.id(file: file), path: file, name: (file as NSString).lastPathComponent, depth: depth,
                    kind: .file(list.marks[file]), ignored: list.isIgnored(file), changed: false
                ))
            }
        }
        walk("", depth: 0)
        return rows
    }

    /// A folder's folders and files, each by name, as full paths.
    public static func children(of folder: String, in list: FileList) -> (folders: [String], files: [String]) {
        var folders: [String] = []
        var files: [String] = []
        let prefix = folder.isEmpty ? "" : folder + "/"
        let range = list.range(under: prefix)
        let skip = prefix.utf8.count
        var i = range.lowerBound
        while i < range.upperBound {
            let path = list.paths[i]
            let rest = path.utf8.dropFirst(skip)
            guard !rest.isEmpty else {
                // The folder's own entry (it was listed unread).
                i += 1
                continue
            }
            if let slash = rest.firstIndex(of: UInt8(ascii: "/")) {
                let child = String(path[..<slash])
                folders.append(child)
                // Past everything under it.
                i = max(i + 1, list.range(under: child + "/").upperBound)
            } else {
                files.append(path)
                i += 1
            }
        }
        let byName = { (lhs: String, rhs: String) in
            (lhs as NSString).lastPathComponent.localizedStandardCompare((rhs as NSString).lastPathComponent)
                == .orderedAscending
        }
        return (folders.sorted(by: byName), files.sorted(by: byName))
    }

    /// The folder a row shows for `folder`, and its label: `folder` and the single folders it holds, down to the
    /// first one with files or several folders in it.
    static func chain(_ folder: String, in list: FileList) -> (path: String, name: String) {
        var path = folder
        var name = (folder as NSString).lastPathComponent
        while let only = onlyFolder(in: path, list: list) {
            path = only
            name += "/" + (only as NSString).lastPathComponent
        }
        return (path, name)
    }

    /// The one folder inside `folder` when it holds nothing else.
    private static func onlyFolder(in folder: String, list: FileList) -> String? {
        let prefix = folder + "/"
        let range = list.range(under: prefix)
        guard !range.isEmpty, !list.isUnread(folder) else { return nil }
        let skip = prefix.utf8.count
        var found: String?
        var i = range.lowerBound
        while i < range.upperBound {
            let path = list.paths[i]
            let rest = path.utf8.dropFirst(skip)
            guard let slash = rest.firstIndex(of: UInt8(ascii: "/")) else {
                if rest.isEmpty {
                    i += 1
                    continue
                }
                return nil
            }
            guard found == nil else { return nil }
            let child = String(path[..<slash])
            found = child
            i = max(i + 1, list.range(under: child + "/").upperBound)
        }
        return found
    }

    /// The folders `path` sits in, outermost first: what opens to show it.
    public static func ancestors(of path: String) -> [String] {
        var folders: [String] = []
        var folder = Substring(path)
        while let slash = folder.lastIndex(of: "/") {
            folder = folder[..<slash]
            folders.insert(String(folder), at: 0)
        }
        return folders
    }

    /// The folder row a file or folder sits under, for `h`: its parent as the tree shows it (a chain's last folder).
    public static func parentRow(of id: String, in rows: [Row]) -> Row? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let depth = rows[index].depth
        return rows[..<index].last { $0.depth < depth && $0.isFolder }
    }
}
