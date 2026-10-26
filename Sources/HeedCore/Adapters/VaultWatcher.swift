import CoreServices
import Foundation

/// Watches pk's notes folder with FSEvents (recursive, per file, batched about 200 ms) and the ports file with a
/// dispatch source, and reports what changed on its own queue. No polling: macOS tells it.
public final class VaultWatcher: @unchecked Sendable {
    public enum Change: Sendable, Equatable {
        /// File events in the notes folder, one batch.
        case notes([FileEvent])
        /// The ports file was written (a port reserved by `pk kbn`).
        case ports
    }

    private let projects: String
    private let portsFile: String
    private let onChange: @Sendable (Change) -> Void
    private let queue = DispatchQueue(label: "heed.vault")
    private var stream: FSEventStreamRef?
    private var portsSource: DispatchSourceFileSystemObject?
    private var pendingPorts: DispatchWorkItem?
    private var stopped = false

    public init(projects: String, portsFile: String, onChange: @escaping @Sendable (Change) -> Void) {
        self.projects = projects
        self.portsFile = portsFile
        self.onChange = onChange
    }

    deinit { teardown() }

    public func start() {
        queue.sync {
            startNotes()
            watchPorts()
        }
    }

    /// Call before letting go of the watcher (never from its own callback).
    public func stop() {
        queue.sync { teardown() }
    }

    private func teardown() {
        stopped = true
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        portsSource?.cancel()
        portsSource = nil
        pendingPorts?.cancel()
    }

    // MARK: Notes

    private func startNotes() {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let events = (0 ..< min(count, list.count)).map { index in
                VaultWatcher.event(path: list[index], flags: flags[index])
            }
            watcher.onChange(.notes(events))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [projects] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    static func event(path: String, flags: FSEventStreamEventFlags) -> FileEvent {
        func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
        let rescan = has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagRootChanged)
        return FileEvent(
            path: path,
            isDirectory: has(kFSEventStreamEventFlagItemIsDir) || rescan,
            structural: rescan || has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved)
                || has(kFSEventStreamEventFlagItemRenamed)
        )
    }

    // MARK: Ports file

    /// Watches the file itself, since pk appends to it in place. When it is replaced or deleted the watch moves to
    /// the new file; while there is none, to its folder, until it appears.
    private func watchPorts() {
        portsSource?.cancel()
        portsSource = nil
        guard !stopped else { return }
        let fd = open(portsFile, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                let replaced = !source.data.isDisjoint(with: [.delete, .rename])
                portsChanged()
                if replaced { queue.asyncAfter(deadline: .now() + .milliseconds(100)) { self.watchPorts() } }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            portsSource = source
            return
        }
        let folder = (portsFile as NSString).deletingLastPathComponent
        let folderFD = open(folder, O_EVTONLY)
        guard folderFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: folderFD,
            eventMask: .write,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, FileManager.default.fileExists(atPath: portsFile) else { return }
            portsChanged()
            watchPorts()
        }
        source.setCancelHandler { close(folderFD) }
        source.resume()
        portsSource = source
    }

    private func portsChanged() {
        pendingPorts?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange(.ports) }
        pendingPorts = work
        queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }
}

/// Whether something listens on a local port: Heed's own "Kibana running" check, the same probe pk makes.
public enum PortProbe {
    /// Tries a TCP connection to 127.0.0.1:`port` for at most `timeout`. Blocks its caller that long, so it runs off
    /// the main actor.
    public static func isListening(_ port: Int, timeout: Duration = .milliseconds(200)) -> Bool {
        guard (1 ... 65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let started = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(timeout.components.seconds * 1000 + timeout.components
            .attoseconds / 1_000_000_000_000_000)
        guard poll(&poller, 1, milliseconds) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }

    /// The ports of `ports` that something listens on, probed side by side, off the caller.
    public static func listening(_ ports: Set<Int>) async -> Set<Int> {
        await withTaskGroup(of: Int?.self) { group in
            for port in ports {
                group.addTask { await Task.detached { isListening(port) ? port : nil }.value }
            }
            var found: Set<Int> = []
            for await port in group {
                if let port { found.insert(port) }
            }
            return found
        }
    }
}
