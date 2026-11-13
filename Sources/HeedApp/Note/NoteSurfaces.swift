import AppKit
import HeedCore
import SwiftUI
import WebKit

/// The payload Swift sends to the note web view.
struct NotePayload: Hashable {
    var markdown: String
    var path: String
    /// Wikilink target (raw, as it appears in `[[…]]`) → absolute path or nil when unresolved.
    var links: [String: String?]
    /// Embeds: target → markdown content or image heed-vault: URL.
    var embeds: [String: NoteEmbed]
    /// Scroll fraction (0–1) to restore; nil keeps the current position.
    var scroll: Double?

    struct NoteEmbed: Hashable {
        var markdown: String?
        var imageURL: String?
    }

    init(markdown: String, path: String, links: [String: String?], embeds: [String: NoteEmbed], scroll: Double? = nil) {
        self.markdown = markdown
        self.path = path
        self.links = links
        self.embeds = embeds
        self.scroll = scroll
    }

    init(_ document: NoteDocument) {
        let embeds = document.embeds.mapValues { embed -> NoteEmbed in
            switch embed {
            case let .note(markdown): NoteEmbed(markdown: markdown)
            case let .file(path): NoteEmbed(imageURL: HeedVaultSchemeHandler.url(for: path))
            }
        }
        self.init(markdown: document.markdown, path: document.path, links: document.links, embeds: embeds)
    }

    func jsArguments(keepScroll: Bool) -> [String: Any] {
        var linksDict: [String: Any] = [:]
        for (k, v) in links {
            linksDict[k] = v as Any
        }
        var embedsDict: [String: Any] = [:]
        for (k, v) in embeds {
            var d: [String: Any] = [:]
            if let md = v.markdown { d["markdown"] = md }
            if let url = v.imageURL { d["imageURL"] = url }
            embedsDict[k] = d
        }
        var args: [String: Any] = ["markdown": markdown, "path": path, "links": linksDict, "embeds": embedsDict]
        if !keepScroll { args["scroll"] = scroll ?? 0 }
        return args
    }
}

/// Owns every Note tab's web view, keyed by pane id.
@MainActor
final class NoteSurfaces {
    static let shared = NoteSurfaces()

    private var views: [String: NoteWebView] = [:]
    private var ready: Set<String> = []
    private var wanted: [String: NotePayload] = [:]
    private var drawn: [String: NotePayload] = [:]

    /// A click in the note: gives it the keys.
    var onClick: ((String) -> Void)?
    /// JS posted `{ type: "link", ... }`: open a wikilink or web URL.
    var onLink: ((String, NoteLink) -> Void)?
    /// JS posted `{ type: "reload" }`: re-read from disk.
    var onReload: ((String) -> Void)?

    static var page: URL? { Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "note") }

    static func makeWebView(
        vault: String?,
        receive: @escaping @MainActor ([String: Any]) -> Void
    ) -> NoteWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: NoteWebTheme.script, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        controller.add(NoteMessages(receive), name: "heed")
        if let vault {
            configuration.setURLSchemeHandler(HeedVaultSchemeHandler(vaultRoot: vault), forURLScheme: "heed-vault")
        }
        let view = NoteWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = NoteNavigation.shared
        if let page {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }

    func view(for paneID: String, vault: String?) -> NSView {
        if let existing = views[paneID] {
            existing.removeFromSuperview()
            return existing
        }
        let view = Self.makeWebView(vault: vault) { [weak self] message in
            self?.received(message, paneID: paneID)
        }
        view.onClick = { [weak self] in self?.onClick?(paneID) }
        views[paneID] = view
        return view
    }

    func show(_ payload: NotePayload?, paneID: String) {
        wanted[paneID] = payload
        flush(paneID)
    }

    func scrollPage(_ fraction: Double, paneID: String) {
        views[paneID]?.callAsyncJavaScript(
            "window.heedNote.scrollPage(fraction)", arguments: ["fraction": fraction],
            in: nil, in: .page, completionHandler: nil
        )
    }

    func scrollEdge(top: Bool, paneID: String) {
        views[paneID]?.callAsyncJavaScript(
            "window.heedNote.scrollEdge(top)", arguments: ["top": top],
            in: nil, in: .page, completionHandler: nil
        )
    }

    func close(paneID: String) {
        wanted.removeValue(forKey: paneID)
        drawn.removeValue(forKey: paneID)
        ready.remove(paneID)
        guard let view = views.removeValue(forKey: paneID) else { return }
        view.configuration.userContentController.removeScriptMessageHandler(forName: "heed")
        view.removeFromSuperview()
    }

    private func flush(_ paneID: String) {
        guard let view = views[paneID], ready.contains(paneID) else { return }
        guard let payload = wanted[paneID] else {
            drawn.removeValue(forKey: paneID)
            return
        }
        let keepScroll = drawn[paneID]?.path == payload.path
        drawn[paneID] = payload
        let args = payload.jsArguments(keepScroll: keepScroll)
        view.callAsyncJavaScript(
            "window.heedNote.show(payload)", arguments: ["payload": args], in: nil, in: .page
        ) { result in
            if case let .failure(error) = result { NSLog("heed: note view: \(error)") }
        }
    }

    private func received(_ message: [String: Any], paneID: String) {
        switch message["type"] as? String {
        case "ready":
            ready.insert(paneID)
            drawn.removeValue(forKey: paneID)
            flush(paneID)
        case "link":
            let newTab = (message["newTab"] as? Bool) ?? false
            if let target = message["target"] as? String {
                onLink?(paneID, .wikilink(target: target, path: message["path"] as? String, newTab: newTab))
            } else if let url = message["url"] as? String {
                onLink?(paneID, .webURL(url: url, newTab: newTab))
            }
        case "reload":
            onReload?(paneID)
        default:
            break
        }
    }
}

/// A link event from the note page.
enum NoteLink: Sendable {
    case wikilink(target: String, path: String?, newTab: Bool)
    case webURL(url: String, newTab: Bool)
}

// MARK: Theme

enum NoteWebTheme {
    static var variables: [(String, String)] {
        [
            ("--heed-bg", css(Theme.pane)),
            ("--heed-bg2", css(Theme.bg2)),
            ("--heed-bg3", css(Theme.bg3)),
            ("--heed-line", css(Theme.line)),
            ("--heed-fg", css(Theme.fg)),
            ("--heed-fg2", css(Theme.fg2)),
            ("--heed-fg3", css(Theme.fg3)),
            ("--heed-code", css(Theme.terminalText)),
            ("--heed-muted", css(Theme.dim)),
            ("--heed-link", css(Theme.busy)),
            ("--heed-added", css(Theme.done)),
            ("--heed-syntax-keyword", css(Theme.busy)),
            ("--heed-syntax-string", css(OrgPalette.lime.foreground)),
            ("--heed-syntax-number", css(OrgPalette.orange.foreground)),
            ("--heed-syntax-comment", css(Theme.dim)),
            ("--heed-syntax-type", css(OrgPalette.periwinkle.foreground)),
            ("--heed-syntax-function", css(OrgPalette.sky.foreground)),
            ("--heed-syntax-tag", css(OrgPalette.teal.foreground)),
            ("--heed-font", "\"JetBrains Mono\", ui-monospace, \"SF Mono\", Menlo, monospace"),
            ("--heed-ui-font", "-apple-system, system-ui, sans-serif"),
            ("--heed-font-size", "12px"),
        ]
    }

    static var script: String {
        let rules = variables.map { "\($0.0): \($0.1);" }.joined(separator: " ")
        let literal = String(
            data: (try? JSONEncoder().encode(":root { \(rules) }")) ?? Data(), encoding: .utf8
        ) ?? "\"\""
        return """
        (() => {
          const style = document.createElement('style');
          style.textContent = \(literal);
          document.documentElement.appendChild(style);
        })();
        """
    }

    static func css(_ color: Color, _ opacity: Double = 1) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "transparent" }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return "rgba(\(channels[0]), \(channels[1]), \(channels[2]), \(opacity))"
    }
}

// MARK: WKWebView subclass

final class NoteWebView: WKWebView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let dropped = ["WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward"]
        menu.items.removeAll { dropped.contains($0.identifier?.rawValue ?? "") }
        super.willOpenMenu(menu, with: event)
    }
}

// MARK: Script message handler

private final class NoteMessages: NSObject, WKScriptMessageHandler {
    private let receive: @MainActor ([String: Any]) -> Void

    init(_ receive: @escaping @MainActor ([String: Any]) -> Void) {
        self.receive = receive
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { receive(body) }
    }
}

// MARK: Navigation delegate

@MainActor
private final class NoteNavigation: NSObject, WKNavigationDelegate {
    static let shared = NoteNavigation()

    func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        // Allow the bundled page and heed-vault: requests.
        if url.isFileURL, url.path == NoteSurfaces.page?.path { return .allow }
        if url.scheme == "heed-vault" { return .allow }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: heed-vault: URL scheme handler

/// Serves files under the vault root as `heed-vault:///absolute/path/to/file`.
/// Only reads; never writes; nothing outside the vault is served.
@MainActor
final class HeedVaultSchemeHandler: NSObject, WKURLSchemeHandler {
    let vaultRoot: String
    private var stopped: Set<ObjectIdentifier> = []

    init(vaultRoot: String) {
        self.vaultRoot = (vaultRoot as NSString).standardizingPath
    }

    nonisolated static func url(for path: String) -> String {
        "heed-vault://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }

    func webView(_: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == "heed-vault" else {
            return task.didFailWithError(URLError(.badURL))
        }
        let path = (url.path as NSString).standardizingPath
        guard path.hasPrefix(vaultRoot + "/") else {
            return task.didFailWithError(URLError(.noPermissionsToReadFile))
        }
        let id = ObjectIdentifier(task)
        stopped.remove(id)
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: URL(fileURLWithPath: path))
            }.value
            guard stopped.remove(id) == nil else { return }
            guard let data else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
            task.didReceive(URLResponse(
                url: url, mimeType: Self.mimeType(for: path), expectedContentLength: data.count,
                textEncodingName: nil
            ))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private nonisolated static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "avif": return "image/avif"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }
}

// MARK: NSViewRepresentable

struct NoteWebPane: NSViewRepresentable {
    let paneID: String
    let vault: String?

    func makeNSView(context _: Context) -> NSView {
        NoteSurfaces.shared.view(for: paneID, vault: vault)
    }

    func updateNSView(_: NSView, context _: Context) {}
}
