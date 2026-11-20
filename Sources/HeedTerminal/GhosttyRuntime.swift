import AppKit
import GhosttyKit
import HeedCore

/// The one libghostty app instance. Owns the Ghostty config and the runtime callbacks; surfaces are created from it.
///
/// libghostty calls `wakeup` from its own threads when it has work; we answer with a tick on the main thread. Every
/// other callback arrives on the main thread during a tick. Rendering happens on Ghostty's renderer thread, so none
/// of this blocks the UI.
@MainActor
public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()

    let app: ghostty_app_t?
    private let config: ghostty_config_t?
    private var tickScheduled = false

    /// Called when a surface's process ends and Ghostty asks to close it (`processAlive` false), or the user closed it.
    public var onSurfaceClosed: ((GhosttySurfaceView, _ processAlive: Bool) -> Void)?
    /// A URL ⌘-clicked in a surface (or opened by a program through OSC 8).
    public var onOpenURL: ((GhosttySurfaceView, String) -> Void)?

    /// Every live surface, told when the colour scheme changes.
    private let surfaces = NSHashTable<GhosttySurfaceView>.weakObjects()
    private var appearanceObservation: NSKeyValueObservation?

    private init() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            NSLog("heed: ghostty_init failed")
        }
        let config = ghostty_config_new()
        // The user's own Ghostty config applies, then Heed's pane look on top so panes match the window.
        ghostty_config_load_default_files(config)
        if let overrides = Self.writeOverrides() { ghostty_config_load_file(config, overrides) }
        ghostty_config_finalize(config)
        self.config = config

        var runtime = Self.runtimeConfig()
        app = withUnsafeMutablePointer(to: &runtime) { ghostty_app_new($0, config) }
        if app == nil { NSLog("heed: ghostty_app_new failed") }
        // The terminals' colours follow the app's appearance, as the window does: Heed sets it (`ColorTheme`). New
        // surfaces start in the app's scheme.
        if let app { ghostty_app_set_color_scheme(app, colorScheme) }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GhosttyRuntime.shared.appearanceChanged() } }
        }
    }

    /// Ghostty's light or dark, as the app's appearance is now.
    var colorScheme: ghostty_color_scheme_e {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    private func appearanceChanged() {
        let scheme = colorScheme
        if let app { ghostty_app_set_color_scheme(app, scheme) }
        for view in surfaces.allObjects {
            if let surface = view.surface { ghostty_surface_set_color_scheme(surface, scheme) }
        }
    }

    /// Tells a new surface every scheme change from now on.
    func register(_ view: GhosttySurfaceView) {
        surfaces.add(view)
        if let surface = view.surface { ghostty_surface_set_color_scheme(surface, colorScheme) }
    }

    /// Pane settings that keep a terminal in step with the design: its colours per theme (the theme files), padding
    /// and the mono face. Colours set here directly would win over the theme.
    static func overrides(light: String, dark: String) -> String {
        """
        theme = light:\(light),dark:\(dark)
        \(overrides)
        """
    }

    static let overrides = """
    font-family = JetBrains Mono
    font-size = 12
    window-padding-x = 14
    window-padding-y = 10
    window-padding-balance = false
    cursor-style = block
    confirm-close-surface = false
    wait-after-command = false
    """

    private static func writeOverrides() -> String? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed")
        let file = support.appendingPathComponent("ghostty-panes.conf")
        let light = support.appendingPathComponent("ghostty-light.theme")
        let dark = support.appendingPathComponent("ghostty-dark.theme")
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try ColorTheme.light.ghosttyTheme.write(to: light, atomically: true, encoding: .utf8)
            try ColorTheme.dark.ghosttyTheme.write(to: dark, atomically: true, encoding: .utf8)
            try overrides(light: light.path, dark: dark.path).write(to: file, atomically: true, encoding: .utf8)
            return file.path
        } catch {
            NSLog("heed: could not write \(file.path): \(error)")
            return nil
        }
    }

    /// The C callbacks. Built outside the main actor on purpose: closures written in a main-actor context are
    /// main-actor isolated, and Swift checks that at entry, but libghostty calls `wakeup` from its renderer thread.
    private nonisolated static func runtimeConfig() -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyRuntime.wakeup() },
            action_cb: { _, target, action in GhosttyRuntime.action(target, action) },
            read_clipboard_cb: { userdata, location, state, mimes, count, _ in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state, mimes: mimes, count: count)
            },
            confirm_read_clipboard_cb: { userdata, _, state, _ in
                // Clipboard reads that need confirmation (OSC 52 from a program) are denied rather than prompted.
                let userdata = RawPointer(userdata), state = RawPointer(state)
                MainActor.assumeIsolated {
                    guard let surface = GhosttyRuntime.surface(userdata.value)?.surface else { return }
                    ghostty_surface_deny_clipboard_request(surface, state.value)
                }
            },
            write_clipboard_cb: { _, location, content, count, _ in
                GhosttyRuntime.writeClipboard(location: location, content: content, count: count)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyRuntime.closeSurface(userdata, processAlive: processAlive)
            }
        )
    }

    func tick() {
        tickScheduled = false
        if let app { ghostty_app_tick(app) }
    }

    public func setFocus(_ focused: Bool) {
        if let app { ghostty_app_set_focus(app, focused) }
    }

    // MARK: Callbacks (C function pointers: no captures, may arrive off the main thread)

    private nonisolated static func wakeup() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let runtime = GhosttyRuntime.shared
                guard !runtime.tickScheduled else { return }
                runtime.tickScheduled = true
                runtime.tick()
            }
        }
    }

    /// Opening a URL and a soft config reload are Heed's; every other action keeps libghostty's default (returning
    /// false says so).
    private nonisolated static func action(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
            return reloadConfig(target, soft: action.action.reload_config.soft)
        }
        guard action.tag == GHOSTTY_ACTION_OPEN_URL, target.tag == GHOSTTY_TARGET_SURFACE,
              let handle = target.target.surface, let pointer = action.action.open_url.url
        else { return false }
        let url = String(
            decoding: UnsafeRawBufferPointer(start: pointer, count: Int(action.action.open_url.len)), as: UTF8.self
        )
        let userdata = RawPointer(ghostty_surface_userdata(handle))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let view = surface(userdata.value) else { return }
                GhosttyRuntime.shared.onOpenURL?(view, url)
            }
        }
        return true
    }

    /// A colour scheme change asks for a soft reload: the same config again, which Ghostty re-reads in the new
    /// scheme (the `theme = light:…,dark:…` line), as Ghostty.app answers it. A full reload (re-reading config files)
    /// is not Heed's.
    private nonisolated static func reloadConfig(_ target: ghostty_target_s, soft: Bool) -> Bool {
        guard soft else { return false }
        let handle = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
        let userdata = RawPointer(handle.flatMap { ghostty_surface_userdata($0) })
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let runtime = GhosttyRuntime.shared
                guard let config = runtime.config else { return }
                guard let userdata = userdata.value else {
                    if let app = runtime.app { ghostty_app_update_config(app, config) }
                    return
                }
                // The surface may have closed since: only a live one is reloaded.
                let view = runtime.surfaces.allObjects.first { Unmanaged.passUnretained($0).toOpaque() == userdata }
                if let surface = view?.surface { ghostty_surface_update_config(surface, config) }
            }
        }
        return true
    }

    nonisolated static func surface(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Serves plain-text reads (paste) from the general pasteboard; other MIME types are reported unavailable.
    private nonisolated static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int
    ) -> ghostty_clipboard_read_result_e {
        let requested = (0 ..< count).compactMap { mimes?[$0].map { String(cString: $0) } }
        let userdata = RawPointer(userdata), state = RawPointer(state)
        return MainActor.assumeIsolated {
            guard location == GHOSTTY_CLIPBOARD_STANDARD, let surface = surface(userdata.value)?.surface else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }
            guard let mime = requested.first(where: { $0.hasPrefix("text/plain") }),
                  let text = NSPasteboard.general.string(forType: .string)
            else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
            let bytes = Array(text.utf8)
            mime.withCString { mimePointer in
                bytes.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(bytes.count, 1)) { data in
                        var content = ghostty_clipboard_content_s(mime: mimePointer, data: data, len: bytes.count)
                        withUnsafePointer(to: &content) { contentPointer in
                            var complete = ghostty_clipboard_complete_s(
                                contents: contentPointer, contents_len: 1, available: nil, available_len: 0,
                                confirmed: false, remember: false
                            )
                            ghostty_surface_complete_clipboard_request(surface, &complete, state.value)
                        }
                    }
                }
            }
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }
    }

    /// Copies the plain-text representation of a write (copy, OSC 52) to the general pasteboard.
    private nonisolated static func writeClipboard(
        location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content else { return }
        for index in 0 ..< count {
            let item = content[index]
            guard let mime = item.mime, String(cString: mime).hasPrefix("text/plain"), let data = item.data else {
                continue
            }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
    }

    private nonisolated static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        let userdata = RawPointer(userdata)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let view = surface(userdata.value) else { return }
                GhosttyRuntime.shared.onSurfaceClosed?(view, processAlive)
            }
        }
    }
}

/// A C pointer handed to the main actor. libghostty's callback pointers are only dereferenced there.
struct RawPointer: @unchecked Sendable {
    let value: UnsafeMutableRawPointer?
    init(_ value: UnsafeMutableRawPointer?) { self.value = value }
}
