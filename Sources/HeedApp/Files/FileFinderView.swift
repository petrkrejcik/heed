import HeedCore
import SwiftUI

/// `gf` / `p`: find a file of the task by name (or paste its path, `:line` included); it opens in the Files tab.
struct FileFinderView: View {
    @Environment(AppModel.self) private var model
    let finder: FileFinder

    var body: some View {
        ZStack {
            Theme.scrim.opacity(0.5)
                .onTapGesture { model.cancelFileFinder() }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.fg3)
                    HStack(spacing: 0) {
                        if finder.query.isEmpty {
                            Text("File name, or a path:line").foregroundStyle(Theme.fg3)
                        } else {
                            Text(finder.query)
                        }
                        Theme.fg.frame(width: 1.5, height: 16)
                    }
                    .font(Theme.mono(13))
                    .lineLimit(1)
                    .truncationMode(.head)
                    Spacer(minLength: 0)
                    if let count = fileCount { Text("\(count) files").font(Theme.ui(11)).foregroundStyle(Theme.fg3) }
                }
                .padding(16)
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }

                let rows = finder.rows
                if rows.isEmpty {
                    Text(finder.answered == finder.query ? emptyText : "Finding…")
                        .font(Theme.ui(13)).foregroundStyle(Theme.fg3)
                        .padding(16)
                } else {
                    let first = max(0, min(finder.cursor - 13, rows.count - 14))
                    ForEach(Array(rows.enumerated().dropFirst(first).prefix(14)), id: \.element.id) { index, row in
                        FinderRow(row: row, current: index == finder.cursor, mark: mark(row))
                            .contentShape(Rectangle())
                            .onTapGesture { model.openFinderRow(row) }
                    }
                }

                HStack(spacing: 14) {
                    hint("↩", "open")
                    hint("⌃j ⌃k", "move")
                    hint("⌘V", "paste a path")
                    hint("⎋", "close")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            }
            .frame(width: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .shotRegion(.filesFinder)
        }
    }

    private var list: FileList? { model.finderList }

    private var fileCount: Int? { list.map(\.files.count) }

    private var emptyText: String {
        finder.query.isEmpty ? "Type a file's name; files you open here and changed files show first" : "No files"
    }

    private func mark(_ row: FileFinder.Row) -> FileList.Mark? { list?.marks[row.path] }

    private func hint(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(text: keys)
            Text(text).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
        }
    }
}

private struct FinderRow: View {
    let row: FileFinder.Row
    let current: Bool
    let mark: FileList.Mark?

    var body: some View {
        let folder = (row.path as NSString).deletingLastPathComponent
        HStack(spacing: 8) {
            Image(systemName: row.kind == .location ? "arrow.right.doc.on.clipboard" : "doc")
                .font(.system(size: 10))
                .foregroundStyle(Theme.fg3)
                .frame(width: 14)
            Text((row.path as NSString).lastPathComponent + (row.line.map { ":\($0)" } ?? ""))
                .font(Theme.mono(12.5, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Text(folder).font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            if let mark {
                Text(mark.rawValue).font(Theme.mono(10.5, weight: .bold)).foregroundStyle(FileTreeRow.color(mark))
            }
            if row.kind == .recent { Text("opened").font(Theme.ui(11)).foregroundStyle(Theme.fg3) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(current ? Theme.bg3 : .clear)
        .overlay(alignment: .leading) { if current { Theme.block.frame(width: 2) } }
    }
}
