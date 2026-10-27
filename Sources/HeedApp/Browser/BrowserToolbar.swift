import HeedCore
import SwiftUI

/// A page pane's header: back, forward, reload or stop, the address with a progress line, the HTTP status when it is
/// an error, and out to your default browser. For the mouse; each button runs the command its key does.
struct BrowserToolbar: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    @State private var address = ""
    @FocusState private var editing: Bool

    private var typing: Bool { editing || model.editingAddress == pane.id }

    var body: some View {
        let page = BrowserSurfaces.shared.page(for: pane)
        HStack(spacing: 2) {
            button("chevron.left", "browser.back", enabled: page.canGoBack)
            button("chevron.right", "browser.forward", enabled: page.canGoForward)
            button(page.loading ? "xmark" : "arrow.clockwise", "browser.reload", enabled: true)
            field(page)
                .font(Theme.mono(11.5))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(typing ? Theme.bg3 : Theme.bg2))
                // White where your keys go, as on a pane in INSERT.
                .overlay { if typing { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white, lineWidth: 1) } }
                .overlay(alignment: .bottomLeading) {
                    if page.loading {
                        GeometryReader { geometry in
                            Theme.busy.frame(width: geometry.size.width * page.progress, height: 2)
                        }
                        .frame(height: 2)
                    }
                }
                .padding(.leading, 6)
            if let status = page.status {
                Text("\(status) \(HTTPURLResponse.localizedString(forStatusCode: status))")
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundStyle(Theme.err)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 8)
                    .help("The server answered \(status)")
            }
            button("arrow.up.right.square", "browser.external", enabled: !page.url.isEmpty)
        }
        .onAppear {
            address = page.url
            editing = model.editingAddress == pane.id
        }
        .onChange(of: page.url) { _, url in if !editing { address = url } }
        .onChange(of: model.editingAddress) { _, id in editing = id == pane.id }
        .onChange(of: editing) { _, now in
            if now, model.editingAddress != pane.id {
                model.beginAddressEdit(pane.id)
            } else if !now, model.editingAddress == pane.id {
                model.endAddressEdit()
                address = page.url
            }
        }
    }

    /// Docs shots render offscreen, where a text field can't be drawn: they get the address as text.
    @ViewBuilder
    private func field(_ page: BrowserPage) -> some View {
        if ShotMode.active {
            Text(page.url.isEmpty ? "Search or enter address" : page.url)
                .foregroundStyle(page.url.isEmpty ? Theme.fg3 : Theme.fg)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("Search or enter address", text: $address)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.fg)
                .focused($editing)
                .onSubmit { model.openAddress(address, in: pane.id) }
        }
    }

    private func button(_ symbol: String, _ command: String, enabled: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(enabled ? Theme.fg2 : Theme.fg3.opacity(0.5))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onTapGesture {
                guard enabled else { return }
                model.focusPane(pane.id)
                model.perform(CommandInvocation(name: command))
            }
            .help(model.keyLabel(for: command).map { "\(command) (\($0))" } ?? command)
    }
}
