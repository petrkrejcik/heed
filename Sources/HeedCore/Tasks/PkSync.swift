import Foundation

/// Keeps Heed's tasks in step with pk: one `task.list` at the start (and on the refresh key), a `task.get` per changed
/// note, and a `task.list` again when the ports file changes or the folder changed wholesale. Its pk calls run one at
/// a time, in order, off the main actor; what they find comes back through `apply` as domain changes.
///
/// The app and `heed pk watch` (the e2e script) both run this, so the script checks the code the app uses.
public actor PkSync {
    public typealias Tasks = @Sendable () async -> [WorkTask]
    public typealias Apply = @Sendable ([DomainChange]) async -> Void
    public typealias Report = @Sendable (String) async -> Void

    private let bridge: PkBridge
    private let tasks: Tasks
    private let apply: Apply
    private let report: Report
    private let now: @Sendable () -> Date
    private var watcher: VaultWatcher?
    private var last: Task<Void, Never>?

    public init(
        bridge: PkBridge, tasks: @escaping Tasks, apply: @escaping Apply, report: @escaping Report = { _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.bridge = bridge
        self.tasks = tasks
        self.apply = apply
        self.report = report
        self.now = now
    }

    /// Asks pk where things are, starts watching the notes folder and the ports file there, and queues a list of
    /// every task (`settled` waits for it). Nil (and reported) when pk could not answer.
    public func start() async -> PkPaths? {
        let paths: PkPaths
        do {
            paths = try await bridge.paths()
        } catch {
            await report("\(error)")
            return nil
        }
        let watcher = VaultWatcher(projects: paths.projects, portsFile: paths.portsFile) { [weak self] change in
            guard let self else { return }
            Task { await self.changed(change) }
        }
        watcher.start()
        self.watcher = watcher
        enqueue { await self.list() }
        return paths
    }

    /// Waits until every pk call queued so far is done.
    public func settled() async {
        await last?.value
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// `task.list`, after whatever is already queued.
    public func refresh() async {
        await enqueue { await self.list() }.value
    }

    func changed(_ change: VaultWatcher.Change) {
        switch change {
        case .ports:
            enqueue { await self.list() }
        case let .notes(events):
            guard let notes = TaskSync.notesToRead(events) else {
                enqueue { await self.list() }
                return
            }
            if !notes.isEmpty { enqueue { await self.read(notes) } }
        }
    }

    @discardableResult
    private func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = last
        let next = Task {
            await previous?.value
            await work()
        }
        last = next
        return next
    }

    private func list() async {
        do {
            let result = try await bridge.list()
            let changes = await TaskSync.reconcile(result.tasks, into: tasks(), now: now())
            if !changes.isEmpty { await apply(changes) }
        } catch {
            await report("\(error)")
        }
    }

    /// Re-reads changed notes. A note pk no longer calls a task (deleted, renamed away, `type` changed) that a task
    /// still points at means a task went: one full list settles which.
    private func read(_ notes: [String]) async {
        var gone: [String] = []
        for note in notes {
            do {
                let task = try await bridge.get(note)
                if let change = await TaskSync.update(task, in: tasks(), now: now()) { await apply([change]) }
            } catch let error as PkError where error.isAnswer {
                gone.append(Self.canonical(note))
            } catch {
                await report("\(error)")
                return
            }
        }
        guard !gone.isEmpty else { return }
        let known = await Set(tasks().compactMap(\.notePath).map(Self.canonical))
        if gone.contains(where: known.contains) { await list() }
    }

    /// A note's path with its folder's symlinks resolved, so `/var/…` from pk and `/private/var/…` from FSEvents
    /// compare equal (the file itself may be gone).
    static func canonical(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        guard let resolved = realpath(folder, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved) + "/" + (path as NSString).lastPathComponent
    }
}
