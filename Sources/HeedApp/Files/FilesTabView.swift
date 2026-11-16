import HeedCore
import SwiftUI

/// A Files tab: the checkout's files as a tree (or find in files' results) on the left, the open file on the right in
/// the Diff tab's web view (CodeMirror, `Resources/diff`). Read only; every key is Heed's.
struct FilesTabView: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let active: Bool

    var body: some View {
        let browser = model.filesBrowsers[pane.id] ?? FilesBrowser()
        VStack(spacing: 0) {
            FilesToolbar(pane: pane, browser: browser)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    FilesSide(pane: pane, browser: browser)
                        .frame(width: min(320, max(160, geometry.size.width * 0.3)))
                        .shotRegion(.filesTree)
                    FileView(pane: pane, browser: browser)
                }
            }
            FilesFooter()
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .background(Theme.pane)
        .shotRegion(.filesTab)
        .onAppear { model.filesTabShown(pane.id) }
    }
}

private struct FilesToolbar: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let browser: FilesBrowser

    var body: some View {
        let list = model.fileList(pane.id)
        HStack(spacing: 8) {
            Segments {
                Segment("Files", on: browser.mode == .files) { model.setFilesMode(.files, paneID: pane.id) }
                Segment("Search", on: browser.mode == .search) { model.setFilesMode(.search, paneID: pane.id) }
            }
            if let key = model.keyLabel(for: "files.mode") { KeyCap(text: key) }
            if let key = model.keyLabel(for: "files.pick") {
                KeyCap(text: key)
                Text("find a file").foregroundStyle(Theme.fg3)
            }
            Spacer(minLength: 8)
            if let list {
                Text("\(list.files.count) files" + (list.complete ? "" : ", reading the rest…"))
                    .foregroundStyle(Theme.fg3)
            } else {
                Text("listing files…").foregroundStyle(Theme.fg3)
            }
        }
        .font(Theme.ui(11.5))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .clipped()
        .background(Theme.paneHeader)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// The left side: the tree, or find in files.
private struct FilesSide: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let browser: FilesBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch browser.mode {
            case .files: FilesTree(pane: pane, browser: browser)
            case .search: SearchSide(pane: pane, browser: browser)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { model.clickedFiles(pane.id) }
    }
}

/// The checkout as VS Code's explorer draws it: folders first, chains of single folders on one row, git's marks on
/// the files and a dot on the folders they are in, what git ignores greyed.
private struct FilesTree: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let browser: FilesBrowser

    var body: some View {
        let rows = model.fileRows(pane.id)
        ScrollViewReader { proxy in
            ListScroll {
                ListStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        FileTreeRow(
                            row: row, cursor: row.id == browser.cursor, shown: !row.isFolder && row.path == browser.file
                        )
                        .id(row.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.clickedFileRow(row, paneID: pane.id) }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: browser.cursor) { _, cursor in
                if let cursor { proxy.scrollTo(cursor) }
            }
            .onAppear {
                if let cursor = browser.cursor { proxy.scrollTo(cursor, anchor: .center) }
            }
        }
    }
}

private struct FileTreeRow: View {
    let row: FileTree.Row
    /// `j` / `k` are on it.
    let cursor: Bool
    /// The file open on the right.
    let shown: Bool

    var body: some View {
        HStack(spacing: 6) {
            switch row.kind {
            case let .folder(open, _):
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.fg3)
                    .frame(width: 10)
                Text(row.name).foregroundStyle(row.ignored ? Theme.dim : Theme.fg2).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                if row.changed { Circle().fill(Theme.block).frame(width: 5, height: 5) }
            case let .file(mark):
                Color.clear.frame(width: 10)
                Text(row.name)
                    .foregroundStyle(row.ignored ? Theme.dim : shown ? Theme.fg : Theme.terminalText)
                    .fontWeight(shown ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let mark {
                    Text(mark.rawValue).font(Theme.mono(10.5, weight: .bold)).foregroundStyle(Self.color(mark))
                }
            }
        }
        .font(Theme.mono(11.5))
        .padding(.leading, 10 + CGFloat(row.depth) * 12)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(cursor ? Theme.selected : .clear)
    }

    static func color(_ mark: FileList.Mark) -> Color {
        switch mark {
        case .added, .untracked: Theme.done
        case .deleted: Theme.err
        case .modified, .renamed: Theme.block
        }
    }
}

/// Find in files (`/`).
private struct SearchSide: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let browser: FilesBrowser

    var body: some View {
        VStack(spacing: 8) {
            Text("Find in files").font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.fg2)
            if let key = model.keyLabel(for: "files.search") {
                Text("\(key) to search").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The open file: its path, then its text (or why it is not shown).
private struct FileView: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let browser: FilesBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = browser.file {
                header(path)
                switch browser.text {
                case let .text(text):
                    FileWebArea(paneID: pane.id, payload: FilePayload(
                        path: path, text: text, line: browser.line, visit: browser.visit,
                        query: browser.mode == .search && !browser.search.query.isEmpty ? browser.search.query : nil
                    ))
                case let .some(side):
                    message(side.unshown ?? "", detail: nil)
                case nil:
                    message("Reading \((path as NSString).lastPathComponent)…")
                }
            } else {
                message(
                    "No file open",
                    detail: model.keyLabel(for: "files.pick").map { "\($0) finds one by name" }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.clickedFiles(pane.id) }
    }

    private func header(_ path: String) -> some View {
        let folder = (path as NSString).deletingLastPathComponent
        let list = model.fileList(pane.id)
        return HStack(spacing: 10) {
            HStack(spacing: 0) {
                if !folder.isEmpty { Text(folder + "/").foregroundStyle(Theme.fg3) }
                Text((path as NSString).lastPathComponent).foregroundStyle(Theme.fg)
            }
            .lineLimit(1)
            .truncationMode(.head)
            if let mark = list?.marks[path] {
                Text(mark.rawValue).fontWeight(.bold).foregroundStyle(FileTreeRow.color(mark))
            }
            if list?.isIgnored(path) == true { Text("ignored by git").foregroundStyle(Theme.fg3) }
            Spacer(minLength: 8)
            if let line = browser.line { Text("line \(line)").foregroundStyle(Theme.fg3) }
        }
        .font(Theme.mono(11.5))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private func message(_ text: String, detail: String? = nil) -> some View {
        VStack(spacing: 8) {
            Text(text).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.fg2)
            if let detail { Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The web view, or in screenshots a still of it.
private struct FileWebArea: View {
    let paneID: String
    let payload: FilePayload

    var body: some View {
        if DiffStills.wanted {
            GeometryReader { geometry in
                if let image = DiffStills.shared.image(file: payload, size: geometry.size) {
                    Image(nsImage: image).resizable().frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Theme.pane
                }
            }
        } else if DiffSurfaces.page == nil {
            Text("The file viewer is missing from the app bundle (scripts/bundle.sh copies Resources/diff)")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.err)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffWebPane(paneID: paneID)
                .onAppear { DiffSurfaces.shared.showFile(payload, paneID: paneID) }
                .onChange(of: payload) { _, next in DiffSurfaces.shared.showFile(next, paneID: paneID) }
        }
    }
}

private struct FilesFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            hint("files.open", "files.fold", "open / fold")
            hint("files.search", nil, "find in files")
            hint("files.ask", nil, "ask the agent")
            hint("files.copy", nil, "copy path:line")
            hint("files.refresh", nil, "read again")
            Spacer()
        }
        .font(Theme.ui(11.5))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
        .clipped()
        .background(Theme.paneHeader)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    @ViewBuilder private func hint(_ command: String, _ other: String?, _ label: String) -> some View {
        if let key = model.keyLabel(for: command) {
            HStack(spacing: 5) {
                KeyCap(text: other.flatMap { model.keyLabel(for: $0) }.map { "\(key) \($0)" } ?? key)
                Text(label).foregroundStyle(Theme.fg3)
            }
            .fixedSize()
        }
    }
}
