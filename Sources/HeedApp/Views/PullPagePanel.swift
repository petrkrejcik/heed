import HeedCore
import SwiftUI

/// The task's PR as GitHub shows it, in a panel slid over the task from the right. The rest of the window is dimmed;
/// a click there closes it, as ⎋ and `go` do. Its page is a web view kept by `BrowserSurfaces`, so it is signed in as
/// page tabs are and keeps its place when shown again.
struct PullPagePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                if let ref = model.pullPage {
                    Theme.scrim.opacity(0.45)
                        .contentShape(Rectangle())
                        .onTapGesture { model.closePullPage() }
                        .transition(.opacity)
                    page(PullPages.pane(ref))
                        .frame(width: min(max(geometry.size.width * 0.62, 760), geometry.size.width - 48))
                        .shadow(color: .black.opacity(0.45), radius: 18)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.pullPage != nil)
        }
        .allowsHitTesting(model.pullPage != nil)
    }

    private func page(_ pane: PaneSpec) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BrowserToolbar(pane: pane)
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.fg2)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture { model.closePullPage() }
                    .help("Close (⎋ or \(model.keyText(for: "overlay.item")))")
            }
            .font(Theme.mono(11))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Theme.paneHeader)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            if ShotMode.active || model.isFixture {
                // Fixtures and snapshots stay off the network.
                FakeBrowser(pane: pane)
            } else {
                BrowserPane(pane: pane, isFocused: model.mode == .insert, focusRequest: model.terminalFocusRequest)
                    .id(pane.id)
                    .overlay {
                        if let failure = BrowserSurfaces.shared.page(for: pane).failure {
                            PageFailure(message: failure)
                        }
                    }
            }
        }
        .background(Theme.pane)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
        // A ring where your keys go, as on a pane in INSERT.
        .overlay { if model.mode == .insert { Rectangle().strokeBorder(Theme.typing, lineWidth: 1.5) } }
    }
}
