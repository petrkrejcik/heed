import HeedCore
import SwiftUI

/// Repos & worktrees (design/screens/Repos.png): repos on the left, every added worktree in a table.
struct ReposView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            repoColumn.shotRegion(.repoColumn)
            table.shotRegion(.worktreeTable)
        }
    }

    private var repoColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Repos").padding(.horizontal, 16).padding(.vertical, 14)
            row(name: "All", count: model.worktreeRows.count, repo: nil)
            ListScroll {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.sortedRepos) { record in
                        row(
                            name: record.repo.name,
                            count: model.worktreeRowCounts[record.id] ?? 0,
                            repo: record.repo
                        )
                    }
                }
            }
            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                keyRow("a", "add repo (rescan roots)")
                keyRow("R", "rescan")
                keyRow("n", "new worktree")
                keyRow("dd", "remove worktree (asks)")
            }
            .padding(16)
        }
        .frame(width: 220)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }

    private func row(name: String, count: Int, repo: Repo?) -> some View {
        HStack(spacing: 8) {
            if let repo {
                OrgTile(org: repo.org, color: repo.color, size: 16)
            }
            Text(name).font(Theme.mono(12.5)).foregroundStyle(repo == nil ? Theme.fg : Theme.fg2)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(count)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(repo == nil ? Theme.bg3 : .clear)
    }

    private func keyRow(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            KeyCap(text: key)
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
        }
    }

    private var table: some View {
        let rows = model.worktreeRows
        let selected = model.selectedRows
        return VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ListScroll {
                    ListStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, worktree in
                            WorktreeRow(
                                worktree: worktree,
                                session: model.session(for: worktree),
                                number: index == model.repoCursor ? index + 1 : abs(index - model.repoCursor),
                                isCursor: index == model.repoCursor,
                                isSelected: selected.contains(worktree.id),
                                roots: model.settings.pathRoots,
                                query: model.filter(for: .repos),
                                pilot: model.session(for: worktree).flatMap { model.pilotStatus(of: $0) },
                                registration: model.registration(of: worktree),
                                hostColor: worktree.location.hostName.flatMap { model.config.hosts[$0]?.color }
                            )
                            .hint(model.hintLabel(for: .row(.repos, index)))
                            .contentShape(Rectangle())
                            .onTapGesture { model.clickRow(.repos, index) }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                model.clickRow(.repos, index, open: true)
                            })
                            .id(worktree.id)
                        }
                    }
                }
                .onChange(of: model.repoCursor) {
                    if rows.indices.contains(model.repoCursor) { proxy.scrollTo(rows[model.repoCursor].id) }
                }
            }
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text(model.repos.isEmpty ? "No repos found yet."
                        : model.worktreeCount > 0 ? "No worktrees match /\(model.filter(for: .repos))."
                        : "No worktrees yet.")
                        .foregroundStyle(Theme.fg2)
                    if model.worktreeCount == 0 { Text(model.repos.isEmpty
                            ? "Scanning \(model.settings.repoRoots.joined(separator: ", ")) for repositories."
                            : "Start work (o) creates one under \(model.settings.worktreeRoot).")
                        .foregroundStyle(Theme.fg3)
                    }
                }
                .font(Theme.ui(12.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 64)
            Group {
                Text("REPO").frame(width: 140, alignment: .leading)
                Text("HOST").frame(width: 96, alignment: .leading)
                Text("BRANCH").frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                Text("AGENT").frame(width: 90, alignment: .leading)
                Text("STATUS").frame(width: 120, alignment: .leading)
                Text("PR").frame(width: 110, alignment: .leading)
            }
            .font(Theme.ui(10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Theme.fg3)
            FilterPill(view: .repos).padding(.leading, 8)
        }
        .padding(.trailing, 16)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

private struct WorktreeRow: View {
    let worktree: Worktree
    let session: Session?
    let number: Int
    let isCursor: Bool
    let isSelected: Bool
    let roots: [String]
    /// The view's filter, marked where it matches.
    let query: String
    /// The state of the session's PR, by the PR number.
    let pilot: PilotStatus?
    var registration: WorktreeRegistration = .registered
    var hostColor: String?

    var body: some View {
        HStack(spacing: 0) {
            Text("\(number)")
                .font(Theme.mono(11, weight: isCursor ? .bold : .regular))
                .foregroundStyle(isCursor ? Theme.fg : Theme.fg3)
                .frame(width: 30, alignment: .trailing)
            Group {
                if let session {
                    StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                } else {
                    StateGlyph(state: .idle)
                }
            }
            .frame(width: 34)
            RepoChip(repo: worktree.repo, highlight: query).frame(width: 140, alignment: .leading)
            HostChip(location: worktree.location, color: hostColor).frame(width: 96, alignment: .leading)
            // The branch, and the worktree's path small below it.
            VStack(alignment: .leading, spacing: 2) {
                Highlighted(text: worktree.branch ?? "detached \(worktree.head)", query: query)
                    .font(Theme.mono(12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                WorktreePath(path: worktree.path, roots: roots, query: query)
            }
            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            Text(session?.agent ?? "—").font(Theme.mono(12)).foregroundStyle(Theme.fg2).frame(
                width: 90,
                alignment: .leading
            )
            Group {
                if registration != .registered {
                    // Found on a host and not heed's yet (↩ registers it), or a host that does not answer.
                    RegistrationChip(registration: registration)
                } else if let status = worktree.status {
                    WorktreeStatusLine(status: status, showUpstream: false)
                } else {
                    Text("…").foregroundStyle(Theme.fg3)
                }
            }
            .frame(width: 120, alignment: .leading)
            HStack(spacing: 6) {
                Text(session?.trackedPRs.first { $0.repo == worktree.repo }.map { "#\(String($0.number))" } ?? "no PR")
                    .font(Theme.mono(12))
                    .foregroundStyle(session?.trackedPRs.isEmpty == false ? Theme.fg : Theme.fg3)
                if let pilot, pilot != .unwatched { PilotMark(status: pilot, compact: true) }
            }
            .frame(width: 110, alignment: .leading)
        }
        .padding(.trailing, 16)
        .frame(height: 48)
        .background(isSelected ? Theme.block.opacity(0.18) : isCursor ? Theme.bg3 : .clear)
        .overlay(alignment: .bottom) { Theme.line.opacity(0.6).frame(height: 1) }
    }
}
