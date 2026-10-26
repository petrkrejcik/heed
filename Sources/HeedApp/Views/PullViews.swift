import HeedCore
import SwiftUI

/// `go` over a session: its PRs, one at a time (design/screens/PROverlay.png).
struct PullOverlayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let ref = model.shownPull {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Color.black.opacity(0.45).frame(width: min(330, geometry.size.width * 0.25))
                    VStack(spacing: 0) {
                        tabs(current: ref)
                        PullDetailView(ref: ref, backHint: false)
                    }
                    .background(Theme.bg)
                }
            }
        }
    }

    private func tabs(current: PullRef) -> some View {
        HStack(spacing: 10) {
            ForEach(model.currentSession?.trackedPRs ?? [], id: \.self) { ref in
                HStack(spacing: 6) {
                    RepoChip(repo: ref.repo).fixedSize()
                    Text(verbatim: "#\(ref.number)").font(Theme.mono(12))
                        .foregroundStyle(ref == current ? Theme.fg : Theme.fg3)
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(ref == current ? Theme.fg3 : .clear))
            }
            KeyCap(text: "]p")
            KeyCap(text: "[p")
            Text("PRs of this session").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            Spacer()
            KeyCap(text: "go")
            Text("or").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            KeyCap(text: "⎋")
            Text("back to session").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// The in-app reader for a PR (design/screens/Reader.png).
struct ReaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let ref = model.reader {
            PullDetailView(ref: ref).background(Theme.bg)
        }
    }
}

/// A PR, read-only: its description, open review threads with the diff they are on, and failing checks; beside them
/// what links to it, its reviewers, checks and green rules. The PR overlay and the reader both show it.
struct PullDetailView: View {
    @Environment(AppModel.self) private var model
    let ref: PullRef
    /// The reader says how to go back; the overlay's tabs already do.
    var backHint = true

    var body: some View {
        let detail = model.pullDetails[ref.description]
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ListScroll {
                    VStack(alignment: .leading, spacing: 14) {
                        header(detail)
                        if let detail {
                            card {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("\(detail.author ?? "someone") opened this").font(Theme.ui(12))
                                        .foregroundStyle(Theme.fg3)
                                    Text(detail.body.isEmpty ? "(no description)" : detail.body).font(Theme.ui(13))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            ForEach(detail.threads.filter { !$0.isResolved }) { thread in
                                threadCard(thread)
                            }
                            ForEach(detail.failingChecks, id: \.name) { check in
                                card {
                                    HStack(spacing: 8) {
                                        Text("\(check.name) failed").foregroundStyle(Theme.err)
                                        Text(check.summary).font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                                            .lineLimit(1)
                                    }
                                    .font(Theme.ui(12.5))
                                }
                            }
                        } else {
                            Text("Fetching \(ref)…").foregroundStyle(Theme.fg3)
                        }
                    }
                    .padding(24)
                }
                if geometry.size.width >= 1000 { side(detail) }
            }
        }
    }

    private func header(_ detail: PullDetail?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RepoChip(repo: ref.repo)
                Text(verbatim: "#\(ref.number)").font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                if let pull = model.github.pull(ref) { StateTag(state: pull.state, draft: pull.isDraft) }
                PullMark(status: model.pullStatus(for: ref))
                Spacer()
                if backHint {
                    KeyCap(text: "⌃o")
                    Text("back").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                }
            }
            Text(detail?.title ?? model.github.pull(ref)?.title ?? "").font(Theme.ui(17, weight: .semibold))
            if let detail {
                Text(
                    "\(detail.headBranch) → \(detail.baseBranch) · \(detail.commitCount) commits · +\(detail.additions) −\(detail.deletions) · fetched \(Clock.relative(detail.fetchedAt, named: true))"
                )
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.fg3)
            }
        }
    }

    private func threadCard(_ thread: ReviewThread) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("@\(thread.author)").fontWeight(.medium)
                Text("commented on").foregroundStyle(Theme.fg3)
                Text(thread.location).font(Theme.mono(12))
                Spacer()
                if thread.replies > 0 {
                    Text("\(thread.replies) repl\(thread.replies == 1 ? "y" : "ies")").foregroundStyle(Theme.fg3)
                }
            }
            .font(Theme.ui(12.5))
            .padding(12)
            if !thread.diff.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(thread.diff.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(line.hasPrefix("-") ? Theme.err : line.hasPrefix("+") ? Theme.done : Theme
                                .fg2)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                            .background(line.hasPrefix("-") ? Theme.err.opacity(0.12)
                                : line.hasPrefix("+") ? Theme.done.opacity(0.12) : .clear)
                    }
                }
                .padding(.vertical, 6)
                .background(Theme.pane)
            }
            Text(thread.body).font(Theme.ui(13)).padding(12).fixedSize(horizontal: false, vertical: true)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private func side(_ detail: PullDetail?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Linked")
            if let session = model.sessions.first(where: { $0.trackedPRs.contains(ref) }) {
                HStack(spacing: 8) {
                    StateGlyph(state: session.state.state)
                    Text(session.branch).font(Theme.mono(12))
                }
            }
            ForEach(detail?.closes ?? [], id: \.self) { issue in
                HStack(spacing: 6) {
                    RepoChip(repo: issue.repo)
                    Text(verbatim: "closes #\(issue.number)").font(Theme.mono(12))
                }
            }
            SectionHeader(title: "Reviewers")
            ForEach(detail?.latestReviews ?? [], id: \.author) { review in
                Text("@\(review.author) · \(review.state.lowercased().replacingOccurrences(of: "_", with: " "))")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.fg2)
            }
            SectionHeader(title: "Checks")
            if let checks = detail?.checks ?? model.github.pull(ref)?.checks {
                Text("\(checks.passed) passed · \(checks.failed) failed · \(checks.pending) pending")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(checks.failed > 0 ? Theme.err : Theme.fg2)
            }
            if let detail {
                SectionHeader(title: "Green")
                ForEach(GreenVerdict.of(detail).rules) { rule in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(rule.state == .pass ? "✓" : rule.state == .fail ? "✕" : "◌")
                            .font(Theme.mono(11.5))
                            .foregroundStyle(rule.state == .pass ? Theme.done : rule.state == .fail ? Theme.err : Theme
                                .busy)
                        Text(rule.name).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                        Text(rule.detail).font(Theme.ui(12)).foregroundStyle(Theme.fg3).lineLimit(1)
                    }
                }
            }
            let mentions = model.suggestedLinks(for: ref)
            if !mentions.isEmpty {
                // PRs that link here but are not this session's own: someone else's, or older than the session.
                SectionHeader(title: "Also mentions it")
                ForEach(mentions, id: \.ref) { mention in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(mention.ref.repo.name)#\(mention.ref.number) \(mention.title)")
                            .font(Theme.ui(12)).lineLimit(1)
                        Text(verbatim: "@\(mention.author ?? "ghost") · :pr.track \(mention.ref.url)")
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1).textSelection(.enabled)
                    }
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                keyRow(model.keyText(for: "pr.start"), "start a new session from this PR")
                keyRow("gB", "open on GitHub")
                keyRow("gS", "jump to its session")
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    private func keyRow(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            KeyCap(text: key)
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
        }
    }
}
