import AppKit
import HeedCore
import Observation
import WebKit

/// The Note tab in screenshots (`HEED_SHOTS`): an offscreen render can't draw a live web view, so the note is drawn by
/// a web view in a window off every screen, snapshotted, and the tab shows that image instead (as `DiffStills`).
@MainActor
@Observable
final class NoteStills {
    static let shared = NoteStills()

    static var wanted: Bool { ShotMode.active }

    struct Key: Hashable {
        var payload: NotePayload
        var width: Int
        var height: Int
    }

    private(set) var images: [Key: NSImage] = [:]
    @ObservationIgnored private var pending: Set<Key> = []

    /// The still for `payload` at `size`, or nil while it is drawn.
    func image(_ payload: NotePayload, size: CGSize) -> NSImage? {
        let key = Key(payload: payload, width: Int(size.width), height: Int(size.height))
        if let image = images[key] { return image }
        guard key.width > 0, key.height > 0, !pending.contains(key) else { return nil }
        pending.insert(key)
        Task { @MainActor in
            let image = await Self.render(key)
            pending.remove(key)
            if let image { images[key] = image }
        }
        return nil
    }

    func settle() async {
        while !pending.isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    var busy: Bool { !pending.isEmpty }

    private static func render(_ key: Key) async -> NSImage? {
        let frame = NSRect(x: -20000, y: -20000, width: key.width, height: key.height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let shown = AsyncStream<String>.makeStream()
        let view = NoteSurfaces.makeWebView(vault: nil) { message in
            if let type = message["type"] as? String { shown.continuation.yield(type) }
        }
        if view.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
            view.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
        view.frame = NSRect(origin: .zero, size: frame.size)
        window.contentView = view
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            shown.continuation.finish()
        }
        defer { timeout.cancel() }
        for await type in shown.stream {
            if type == "ready" {
                _ = try? await view.callAsyncJavaScript(
                    "window.heedNote.show(payload)", arguments: ["payload": key.payload.jsArguments(keepScroll: false)],
                    contentWorld: .page
                )
            } else if type == "shown" {
                break
            }
        }
        try? await Task.sleep(for: .milliseconds(150))
        return try? await view.takeSnapshot(configuration: nil)
    }
}
