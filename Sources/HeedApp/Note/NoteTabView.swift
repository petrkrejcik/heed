import HeedCore
import SwiftUI

/// A Note tab: the note name in a header, then the markdown rendered in a web view.
struct NoteTabView: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let active: Bool

    var body: some View {
        VStack(spacing: 0) {
            NoteHeader(pane: pane, active: active)
            NoteBody(pane: pane, active: active)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .background(Theme.pane)
        .onAppear { model.noteTabShown(pane.id) }
    }
}

// MARK: Header

private struct NoteHeader: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(pane.title)
                .font(Theme.ui(12, weight: .semibold))
                .foregroundStyle(active ? Theme.fg : Theme.fg2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let key = model.keyLabel(for: "note.reload") {
                KeyCap(text: key)
                Text("reload").font(Theme.ui(11)).foregroundStyle(Theme.fg3)
            }
            if let key = model.keyLabel(for: "note.obsidian") {
                KeyCap(text: key)
                Text("Obsidian").font(Theme.ui(11)).foregroundStyle(Theme.fg3)
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

// MARK: Body

private struct NoteBody: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let active: Bool

    var body: some View {
        if NoteSurfaces.page == nil {
            Text("The note viewer is missing from the app bundle (scripts/bundle.sh copies Resources/note)")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.err)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isFixture {
            NoteWebPane(paneID: pane.id, vault: nil)
                .onAppear { showFixtureNote() }
        } else {
            NoteWebPane(paneID: pane.id, vault: model.pkPaths?.vault)
                .contentShape(Rectangle())
                .onTapGesture { model.clickedNote(pane.id) }
        }
    }

    private func showFixtureNote() {
        guard let path = pane.path else { return }
        let markdown = Fixtures.noteContent(at: path) ?? "*(fixture note not found)*"
        let entries = Fixtures.noteEntries
        let links = WikilinkResolver.resolveAll(in: markdown, entries: entries)
        // Convert to [String: String?]
        var linksResolved: [String: String?] = [:]
        for (k, v) in links {
            linksResolved[k] = v
        }
        let payload = NotePayload(
            markdown: markdown, path: path,
            links: linksResolved, embeds: [:]
        )
        NoteSurfaces.shared.show(payload, paneID: pane.id)
    }
}
