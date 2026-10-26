import Foundation

public extension WorkTask {
    /// pk's fields from `pk`; Heed's own (last activity, timeline) from what Heed had. A task new to Heed starts its
    /// activity at its note's `created` day, so a long list of notes sorts by age rather than all at once. Nil when
    /// pk sent no id.
    init?(_ pk: PkTask, keeping existing: WorkTask?, now: Date = Date()) {
        guard let id = pk.id, !id.isEmpty else { return nil }
        self.init(
            id: id, title: pk.title, status: TaskStatus(rawValue: pk.status), pinned: pk.pinned, kind: pk.kind,
            issue: pk.issue, pr: pk.pr, worktree: pk.worktree, branch: pk.branch, notePath: pk.notePath,
            port: pk.port, running: pk.running, epic: pk.epic, created: pk.created,
            lastActivity: existing?.lastActivity ?? pk.created.flatMap(TaskSync.day) ?? now,
            timeline: existing?.timeline ?? []
        )
    }
}

/// Folding pk's answers into the domain, as domain changes. Pure, so every rule is tested without pk.
public enum TaskSync {
    /// A full `task.list`: changed and new tasks upserted, tasks pk no longer has removed (their note was deleted or
    /// is no longer a task). Unchanged tasks produce nothing, so nothing redraws.
    public static func reconcile(_ fresh: [PkTask], into current: [WorkTask], now: Date = Date()) -> [DomainChange] {
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var changes: [DomainChange] = []
        for pk in fresh {
            guard let id = pk.id, seen.insert(id).inserted else { continue }
            if let change = update(pk, existing: byID[id], now: now) { changes.append(change) }
        }
        for task in current where !seen.contains(task.id) {
            changes.append(.taskRemoved(task.id))
        }
        return changes
    }

    /// One task as pk now has it: an upsert when anything pk owns changed, else nothing.
    public static func update(_ fresh: PkTask, in current: [WorkTask], now: Date = Date()) -> DomainChange? {
        update(fresh, existing: current.first { $0.id == fresh.id }, now: now)
    }

    private static func update(_ fresh: PkTask, existing: WorkTask?, now: Date) -> DomainChange? {
        guard let task = WorkTask(fresh, keeping: existing, now: now), task != existing else { return nil }
        return .taskUpserted(task)
    }

    /// The Kibana probe's answer for `probed` ports: tasks whose running flag changed.
    public static func running(listening: Set<Int>, probed: Set<Int>, in tasks: [WorkTask]) -> [DomainChange] {
        tasks.compactMap { task in
            guard let port = task.port, probed.contains(port) else { return nil }
            let running = listening.contains(port)
            guard running != task.running else { return nil }
            var changed = task
            changed.running = running
            return .taskUpserted(changed)
        }
    }

    /// What a batch of file events in the notes folder asks for: the notes to re-read one by one, or nil to list
    /// everything again (a folder moved, or so many notes changed that one list is cheaper). Only `.md` files count;
    /// Obsidian's views and attachments are not tasks.
    public static func notesToRead(_ events: [FileEvent], limit: Int = 5) -> [String]? {
        if events.contains(where: { $0.isDirectory && $0.structural }) { return nil }
        var notes: [String] = []
        for event in events where !event.isDirectory && event.path.hasSuffix(".md") && !notes.contains(event.path) {
            let hidden = event.path.split(separator: "/").contains { $0.hasPrefix(".") }
            if !hidden { notes.append(event.path) }
        }
        return notes.count > limit ? nil : notes
    }

    /// `2026-10-21` as the start of that day, local time.
    static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

/// One path from the notes folder's file events.
public struct FileEvent: Hashable, Sendable {
    public var path: String
    public var isDirectory: Bool
    /// Created, removed or renamed, rather than only written.
    public var structural: Bool

    public init(path: String, isDirectory: Bool = false, structural: Bool = false) {
        self.path = path
        self.isDirectory = isDirectory
        self.structural = structural
    }
}
