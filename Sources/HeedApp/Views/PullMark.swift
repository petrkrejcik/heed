import HeedCore
import SwiftUI

/// A PR's state, small: what the sidebar, the PRs view, Repos and the inspector show next to a PR.
struct PullMark: View {
    let status: PullStatus
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Text(glyph)
            if !compact || text.count <= 4 { Text(text) }
        }
        .font(Theme.mono(compact ? 10.5 : 11.5, weight: .medium))
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
    }

    private var glyph: String {
        switch status {
        case .failing: "✕"
        case .conflicted: "⇄"
        case .changes: "●"
        case .pending, .draft: "◌"
        case .green, .passing: "✓"
        case let .closed(merged): merged ? "✓" : "✕"
        }
    }

    var text: String {
        switch status {
        case let .failing(count): "\(count) failing"
        case let .changes(count): "\(count) thread\(count == 1 ? "" : "s")"
        case let .conflicted(what): what.hasPrefix("behind") ? "behind" : "conflict"
        case .pending: "running"
        case .draft: "draft"
        case .green: "green"
        case .passing: "passing"
        case let .closed(merged): merged ? "merged" : "closed"
        }
    }

    private var color: Color {
        switch status {
        case .failing, .conflicted: Theme.err
        case .changes: Theme.block
        case .pending: Theme.busy
        case .green: Theme.done
        case .passing: Theme.fg2
        case .draft, .closed: Theme.fg3
        }
    }
}
