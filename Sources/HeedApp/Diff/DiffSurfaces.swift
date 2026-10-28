import AppKit
import HeedCore
import SwiftUI
import WebKit

/// What a Diff tab's web view draws: one file's two sides, in one mode.
struct DiffPayload: Hashable {
    var path: String
    var language: String?
    var old: String
    var new: String
    var split: Bool
    /// After drawing, go to the file's first or last hunk (`n` past the end of the previous file).
    var focus: Focus?

    enum Focus: String { case first, last }

    init(contents: FileContents, split: Bool, focus: Focus? = nil) {
        path = contents.path
        language = DiffLanguage.of(contents.path)
        old = contents.old.text ?? ""
        new = contents.new.text ?? ""
        self.split = split
        self.focus = focus
    }

    /// The same drawing: where it lands does not matter.
    func draws(like other: DiffPayload?) -> Bool {
        guard let other else { return false }
        return path == other.path && old == other.old && new == other.new && split == other.split
            && language == other.language
    }

    func arguments(keepScroll: Bool) -> [String: Any] {
        [
            "path": path, "language": language ?? NSNull(), "old": old, "new": new,
            "mode": split ? "split" : "unified", "keepScroll": keepScroll, "focus": focus?.rawValue ?? NSNull(),
        ]
    }
}

/// The Diff tab's colours and font, as the CSS variables `Resources/diff` reads: Heed's tokens, so a light theme only
/// changes them here.
enum DiffWebTheme {
    static var variables: [(String, String)] {
        [
            ("--heed-bg", css(Theme.pane)), ("--heed-bg2", css(Theme.bg2)), ("--heed-bg3", css(Theme.bg3)),
            ("--heed-line", css(Theme.line)), ("--heed-fg", css(Theme.fg)), ("--heed-code", css(Theme.terminalText)),
            ("--heed-muted", css(Theme.fg3)), ("--heed-gutter", css(Theme.dim)),
            ("--heed-added", css(Theme.done)), ("--heed-deleted", css(Theme.err)),
            ("--heed-added-line", css(Theme.done, 0.1)), ("--heed-deleted-line", css(Theme.err, 0.1)),
            ("--heed-added-text", css(Theme.done, 0.3)), ("--heed-deleted-text", css(Theme.err, 0.3)),
            ("--heed-selection", css(Theme.busy, 0.3)), ("--heed-current", css(Theme.block)),
            ("--heed-syntax-keyword", css(Theme.busy)), ("--heed-syntax-string", css(OrgPalette.lime.foreground)),
            ("--heed-syntax-number", css(OrgPalette.orange.foreground)), ("--heed-syntax-comment", css(Theme.dim)),
            ("--heed-syntax-type", css(OrgPalette.periwinkle.foreground)),
            ("--heed-syntax-function", css(OrgPalette.sky.foreground)),
            ("--heed-syntax-tag", css(OrgPalette.teal.foreground)),
            ("--heed-font", "\"JetBrains Mono\", ui-monospace, \"SF Mono\", Menlo, monospace"),
            ("--heed-ui-font", "-apple-system, system-ui, sans-serif"), ("--heed-font-size", "12px"),
        ]
    }

    /// Sets the variables before the page's own script runs.
    static var script: String {
        let rules = variables.map { "\($0.0): \($0.1);" }.joined(separator: " ")
        let literal = String(data: (try? JSONEncoder().encode(
            ":root { \(rules) }"
        )) ?? Data(), encoding: .utf8) ?? "\"\""
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

/// Owns every Diff tab's web view, keyed by pane id, as `BrowserSurfaces` does pages: made when the tab is first
/// drawn, kept across re-layout, gone with the tab. The page is the bundled `Resources/diff`, loaded from the app
/// bundle; nothing it does reaches the network.
@MainActor
final class DiffSurfaces {
    static let shared = DiffSurfaces()
    private var views: [String: DiffWebView] = [:]
    private var ready: Set<String> = []
    /// What each tab should show, and what its page shows now.
    private var wanted: [String: DiffPayload] = [:]
    private var drawn: [String: DiffPayload] = [:]

    /// The web view reported the hunk or line you are on.
    var onCursor: ((String, DiffCursor) -> Void)?
    /// A click in the diff: its pane takes the keys (NORMAL stays).
    var onClick: ((String) -> Void)?

    static var page: URL? { Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "diff") }

    /// A web view on the diff page, answering `receive` with the page's messages.
    static func makeWebView(receive: @escaping @MainActor ([String: Any]) -> Void) -> DiffWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: DiffWebTheme.script, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        controller.add(DiffMessages(receive), name: "heed")
        let view = DiffWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = DiffNavigation.shared
        if let page {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }

    func view(for paneID: String) -> NSView {
        if let existing = views[paneID] {
            existing.removeFromSuperview()
            return existing
        }
        let view = Self.makeWebView { [weak self] message in self?.received(message, paneID: paneID) }
        view.onClick = { [weak self] in self?.onClick?(paneID) }
        views[paneID] = view
        return view
    }

    func isDiffView(_ view: NSView) -> Bool { views.values.contains { $0 === view } }

    /// Draws `payload` in the tab (nil: nothing). A page not loaded yet draws it once it is.
    func show(_ payload: DiffPayload?, paneID: String) {
        wanted[paneID] = payload
        flush(paneID)
    }

    /// `n` / `N`: false when there is no next (previous) hunk in this file.
    func hunk(_ delta: Int, paneID: String) async -> Bool {
        guard let view = views[paneID], ready.contains(paneID) else { return false }
        let moved = try? await view.callAsyncJavaScript(
            "return window.heedDiff.hunk(delta)", arguments: ["delta": delta], contentWorld: .page
        )
        return (moved as? Bool) ?? false
    }

    /// `t`: the same file side by side or unified, on the same hunk.
    func setSplit(_ split: Bool, paneID: String) {
        guard var payload = wanted[paneID], payload.split != split else { return }
        payload.split = split
        payload.focus = nil
        wanted[paneID] = payload
        guard let view = views[paneID], ready.contains(paneID) else { return }
        drawn[paneID] = payload
        view.callAsyncJavaScript(
            "window.heedDiff.setMode(mode)", arguments: ["mode": split ? "split" : "unified"], in: nil,
            in: .page, completionHandler: nil
        )
    }

    /// `⌃d` / `⌃u`: half a page down or up.
    func scrollPage(_ fraction: Double, paneID: String) {
        views[paneID]?.callAsyncJavaScript(
            "window.heedDiff.scrollPage(fraction)", arguments: ["fraction": fraction], in: nil, in: .page,
            completionHandler: nil
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
            if drawn.removeValue(forKey: paneID) != nil {
                view.callAsyncJavaScript("window.heedDiff.clear()", arguments: [:], in: nil, in: .page) { _ in }
            }
            return
        }
        guard !payload.draws(like: drawn[paneID]) else { return }
        let keepScroll = drawn[paneID]?.path == payload.path
        drawn[paneID] = payload
        view.callAsyncJavaScript(
            "window.heedDiff.show(payload)", arguments: ["payload": payload.arguments(keepScroll: keepScroll)],
            in: nil, in: .page
        ) { result in
            if case let .failure(error) = result { NSLog("heed: diff view: \(error)") }
        }
    }

    private func received(_ message: [String: Any], paneID: String) {
        switch message["type"] as? String {
        case "ready":
            // The page (re)loaded: it shows nothing until told again.
            ready.insert(paneID)
            drawn.removeValue(forKey: paneID)
            flush(paneID)
        case "cursor":
            if let cursor = DiffCursor(message: message) { onCursor?(paneID, cursor) }
        default:
            break
        }
    }
}

extension DiffCursor {
    init?(message: [String: Any]) {
        guard let path = message["path"] as? String, let line = (message["line"] as? NSNumber)?.intValue else {
            return nil
        }
        self.init(
            path: path, line: line, side: Side(rawValue: message["side"] as? String ?? "b") ?? .new,
            hunk: (message["hunk"] as? NSNumber)?.intValue ?? 0, hunks: (message["hunks"] as? NSNumber)?.intValue ?? 0
        )
    }
}

/// The diff page's web view: says when it is clicked, so the click focuses its tab.
final class DiffWebView: WKWebView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }

    /// No Reload, Back or Forward in the page's menu: they would lose the diff.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let dropped = ["WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward"]
        menu.items.removeAll { dropped.contains($0.identifier?.rawValue ?? "") }
        super.willOpenMenu(menu, with: event)
    }
}

/// The page's messages, without the user content controller keeping the surfaces alive.
private final class DiffMessages: NSObject, WKScriptMessageHandler {
    private let receive: @MainActor ([String: Any]) -> Void

    init(_ receive: @escaping @MainActor ([String: Any]) -> Void) {
        self.receive = receive
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { receive(body) }
    }
}

/// The diff page loads once, from the bundle; it never navigates anywhere else (a dropped file, a link).
@MainActor
private final class DiffNavigation: NSObject, WKNavigationDelegate {
    static let shared = DiffNavigation()

    func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, url.isFileURL, url.path == DiffSurfaces.page?.path else { return .cancel }
        return .allow
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

/// A Diff tab's web view in the window.
struct DiffWebPane: NSViewRepresentable {
    let paneID: String

    func makeNSView(context _: Context) -> NSView {
        DiffSurfaces.shared.view(for: paneID)
    }

    func updateNSView(_: NSView, context _: Context) {}
}
