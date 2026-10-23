import HeedCore
import SwiftUI

/// A watched PR's state, small: what the sidebar, the PRs view and Repos show next to a PR.
struct PilotMark: View {
    let status: PilotStatus
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
        case .stuck: "⚠"
        case .stalled: "⏹"
        case .failing: "✕"
        case .conflicted: "⇄"
        case .changes: "●"
        case .feeding: "⟳"
        case .pending, .draft: "◌"
        case .green, .passing: "✓"
        case .paused: "⏸"
        case let .closed(merged): merged ? "✓" : "✕"
        case .unwatched: "○"
        }
    }

    var text: String {
        switch status {
        case .stuck: "stuck"
        case .stalled: "stalled"
        case let .failing(count): "\(count) failing"
        case let .changes(count): "\(count) thread\(count == 1 ? "" : "s")"
        case .feeding: "feeding"
        case let .conflicted(what): what.hasPrefix("behind") ? "behind" : "conflict"
        case .pending: "running"
        case .draft: "draft"
        case .green: "green"
        case .passing: "passing"
        case let .closed(merged): merged ? "merged" : "closed"
        case let .paused(until): until.map { PilotDuration.text($0.timeIntervalSince(Clock.now)) } ?? "paused"
        case .unwatched: "not watched"
        }
    }

    private var color: Color {
        switch status {
        case .stuck: Theme.block
        case .stalled, .failing, .conflicted: Theme.err
        case .changes: Theme.block
        case .feeding, .pending: Theme.busy
        case .green: Theme.done
        case .passing: Theme.fg2
        case .draft, .paused, .closed, .unwatched: Theme.fg3
        }
    }
}
