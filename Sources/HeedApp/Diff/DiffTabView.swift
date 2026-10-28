import HeedCore
import SwiftUI

/// A Diff tab: the scope and the view mode on top, the changed files as a folder tree on the left, the file you are
/// on on the right in the web view (CodeMirror's merge view, `Resources/diff`). Read only; every key is Heed's.
struct DiffTabView: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let active: Bool

    var body: some View {
        let review = model.diffReviews[pane.id] ?? DiffReview()
        VStack(spacing: 0) {
            DiffToolbar(pane: pane, review: review)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    DiffFileList(pane: pane, review: review)
                        .frame(width: min(300, max(180, geometry.size.width * 0.28)))
                    DiffFileView(pane: pane, review: review)
                }
            }
            DiffFooter()
        }
        .background(Theme.pane)
        .onAppear { model.diffTabShown(pane.id) }
    }
}

private struct DiffToolbar: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let review: DiffReview

    var body: some View {
        HStack(spacing: 8) {
            Segments {
                ForEach(DiffScope.cycle, id: \.self) { scope in
                    Segment(scope.title, on: review.scope == scope) { model.setDiffScope(scope, paneID: pane.id) }
                }
                if case let .commit(sha) = review.scope { Segment(sha, on: true) {} }
            }
            KeyCap(text: "⇥")
            if model.keyLabel(for: "diff.commit") != nil {
                KeyCap(text: model.keyLabel(for: "diff.commit") ?? "c")
                Text("commit").foregroundStyle(Theme.fg3)
            }
            if review.loading { Text("reading…").foregroundStyle(Theme.fg3) }
            Spacer(minLength: 8)
            Segments {
                Segment("Side by side", on: model.diffSplit) { model.setDiffSplit(true) }
                Segment("Unified", on: !model.diffSplit) { model.setDiffSplit(false) }
            }
            KeyCap(text: model.keyLabel(for: "diff.split") ?? "t")
        }
        .font(Theme.ui(11.5))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.paneHeader)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

private struct Segments<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .fixedSize()
    }
}

private struct Segment: View {
    let label: String
    let on: Bool
    let action: () -> Void

    init(_ label: String, on: Bool, action: @escaping () -> Void) {
        self.label = label
        self.on = on
        self.action = action
    }

    var body: some View {
        Text(label)
            .font(Theme.ui(11.5, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Theme.ink : Theme.fg2)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(on ? Theme.inverse : .clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// The changed files as VS Code's source control tree: folders (a chain of single folders on one row) fold with a
/// click; each file has its status letter, the staged dot and its added and removed lines.
private struct DiffFileList: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let review: DiffReview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsCommits {
                header("Commits", key: model.keyLabel(for: "diff.commit"))
                ForEach(review.commits) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(commit.sha).foregroundStyle(Theme.fg3)
                        Text(commit.subject).lineLimit(1).truncationMode(.tail)
                    }
                    .font(Theme.mono(11))
                    .foregroundStyle(review.scope == .commit(commit.sha) ? Theme.fg : Theme.fg2)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .background(review.scope == .commit(commit.sha) ? Theme.selected : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { model.setDiffScope(.commit(commit.sha), paneID: pane.id) }
                }
            }
            header("Files", count: review.files.count)
            ListScroll {
                ListStack(alignment: .leading, spacing: 0) {
                    ForEach(review.tree.rows(collapsed: review.collapsed)) { row in
                        DiffTreeRow(row: row, selected: row.id == "file:\(review.selected ?? "")")
                            .contentShape(Rectangle())
                            .onTapGesture {
                                switch row.kind {
                                case .folder: model.toggleDiffFolder(row.id, paneID: pane.id)
                                case let .file(file): model.selectDiffFile(file.path, paneID: pane.id)
                                }
                            }
                    }
                }
                .padding(.bottom, 8)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().fill(Theme.done).frame(width: 6, height: 6)
                    Text("staged")
                }
                HStack(spacing: 4) {
                    Circle().strokeBorder(Theme.done).frame(width: 6, height: 6)
                    Text("not staged")
                }
            }
            .font(Theme.ui(11))
            .foregroundStyle(Theme.fg3)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { model.clickedDiff(pane.id) }
    }

    private var showsCommits: Bool {
        switch review.scope {
        case .committed, .commit: !review.commits.isEmpty
        default: false
        }
    }

    private func header(_ title: String, count: Int? = nil, key: String? = nil) -> some View {
        HStack(spacing: 6) {
            SectionHeader(title: title)
            if let count { Text("\(count)").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3) }
            if let key { KeyCap(text: key) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

private struct DiffTreeRow: View {
    let row: DiffTree.Row
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            switch row.kind {
            case let .folder(name, open):
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.fg3)
                    .frame(width: 10)
                Text(name).foregroundStyle(Theme.fg2).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            case let .file(file):
                Text(file.status.rawValue)
                    .font(Theme.mono(10.5, weight: .bold))
                    .foregroundStyle(statusColor(file.status))
                    .frame(width: 10)
                Text((file.path as NSString).lastPathComponent)
                    .foregroundStyle(selected ? Theme.fg : Theme.terminalText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Circle().fill(file.staged ? Theme.done : .clear).overlay(Circle().strokeBorder(Theme.done))
                    .frame(width: 6, height: 6)
                if file.binary {
                    Text("bin").foregroundStyle(Theme.fg3)
                } else {
                    Text("+\(file.additions)").foregroundStyle(Theme.done)
                    if file.deletions > 0 { Text("−\(file.deletions)").foregroundStyle(Theme.err) }
                }
            }
        }
        .font(Theme.mono(11.5))
        .padding(.leading, 12 + CGFloat(row.depth) * 12)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(selected ? Theme.selected : .clear)
    }

    private func statusColor(_ status: FileDiff.Status) -> Color {
        switch status {
        case .added: Theme.done
        case .deleted: Theme.err
        case .modified, .renamed: Theme.block
        }
    }
}

/// The file you are on: its path and counts, then its diff (or why there is none).
private struct DiffFileView: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let review: DiffReview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let file = review.selectedFile {
                header(file)
                if let contents = review.contents, contents.path == file.path {
                    if let reason = file.binary ? "Binary file" : contents.unshown {
                        message(
                            reason,
                            detail: model.keyLabel(for: "diff.edit").map { "\($0) opens it in your editor" }
                        )
                    } else {
                        DiffWebArea(paneID: pane.id, payload: DiffPayload(contents: contents, split: model.diffSplit))
                            .shotRegion(.diffBody)
                    }
                } else {
                    message("Reading \((file.path as NSString).lastPathComponent)…")
                }
            } else if review.loading || review.loadedAt == nil {
                message("Reading the diff…")
            } else {
                message(
                    "No changes in \(review.scope.title.lowercased())",
                    detail: model.keyLabel(for: "diff.scope.next").map { "\($0) shows another scope" }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.clickedDiff(pane.id) }
    }

    private func header(_ file: FileDiff) -> some View {
        let folder = (file.path as NSString).deletingLastPathComponent
        return HStack(spacing: 10) {
            HStack(spacing: 0) {
                if !folder.isEmpty { Text(folder + "/").foregroundStyle(Theme.fg3) }
                Text((file.path as NSString).lastPathComponent).foregroundStyle(Theme.fg)
            }
            .lineLimit(1)
            .truncationMode(.head)
            if let old = file.oldPath { Text("from \(old)").foregroundStyle(Theme.fg3).lineLimit(1) }
            Text("+\(file.additions)").foregroundStyle(Theme.done)
            Text("−\(file.deletions)").foregroundStyle(Theme.err)
            Spacer(minLength: 8)
            if let cursor = review.cursor, cursor.path == file.path, cursor.hunks > 0 {
                Text(cursor.hunk > 0 ? "hunk \(cursor.hunk)/\(cursor.hunks)" : "\(cursor.hunks) hunks")
                    .foregroundStyle(Theme.fg3)
            }
            if let location = review.location { Text("line \(location.line)").foregroundStyle(Theme.fg3) }
            Text("\((review.selectedIndex ?? 0) + 1)/\(review.files.count)").foregroundStyle(Theme.fg2)
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
private struct DiffWebArea: View {
    @Environment(AppModel.self) private var model
    let paneID: String
    let payload: DiffPayload

    var body: some View {
        if DiffStills.wanted {
            GeometryReader { geometry in
                if let image = DiffStills.shared.image(payload, size: geometry.size) {
                    Image(nsImage: image).resizable().frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Theme.pane
                }
            }
        } else if DiffSurfaces.page == nil {
            Text("The diff viewer is missing from the app bundle (scripts/bundle.sh copies Resources/diff)")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.err)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffWebPane(paneID: paneID)
                .onAppear { DiffSurfaces.shared.show(payload, paneID: paneID) }
                .onChange(of: payload) { _, next in DiffSurfaces.shared.show(next, paneID: paneID) }
        }
    }
}

private struct DiffFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            hint("diff.hunk.next", "diff.hunk.prev", "hunk")
            hint("diff.file.next", "diff.file.prev", "file")
            hint("diff.ask", nil, "ask the agent")
            hint("diff.copy", nil, "copy path:line")
            hint("diff.edit", nil, "editor")
            hint("diff.refresh", nil, "read again")
            Spacer()
        }
        .font(Theme.ui(11.5))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 28)
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
