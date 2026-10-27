import AppKit
import HeedCore
import SwiftUI
import WebKit

/// A web page pane: the pane's web view, kept by `BrowserSurfaces` so it survives re-layout as a terminal does. The
/// web view is made the first time the pane is drawn, so a page saved in a tab you have not looked at since a relaunch
/// costs nothing until you do.
struct BrowserPane: NSViewRepresentable {
    let pane: PaneSpec
    /// True when this pane should own the keyboard (focused pane, INSERT).
    let isFocused: Bool
    let focusRequest: Int

    func makeNSView(context _: Context) -> NSView {
        BrowserSurfaces.shared.view(for: pane)
    }

    func updateNSView(_ view: NSView, context _: Context) {
        if isFocused { takeKeyboard(view) }
    }
}

/// Over a page that could not load at all: why, and how to try again.
struct PageFailure: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Text("Can't open the page").font(Theme.ui(15, weight: .medium)).foregroundStyle(Theme.fg)
            Text(message).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).multilineTextAlignment(.center)
            if let key = model.keyLabel(for: "browser.reload") {
                HStack(spacing: 6) {
                    KeyCap(text: key)
                    Text("try again").foregroundStyle(Theme.fg3)
                }
                .font(Theme.ui(11.5))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pane)
    }
}

/// What a page is doing, for its toolbar. The address and title that outlive it are the pane's (`PaneSpec`).
@MainActor @Observable
final class BrowserPage {
    var url: String
    var title = ""
    var loading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    /// The page's HTTP status when it is an error: a 502 with an empty body is otherwise just a white page.
    var status: Int?
    /// Why the page could not load at all (no server, bad address); nil once a load starts.
    var failure: String?

    init(url: String?) {
        self.url = url ?? ""
    }
}

/// Owns every page pane's web view and state, keyed by pane id. One cookie store for all of them: you sign in to a
/// host once, and it stays signed in across relaunches.
@MainActor
final class BrowserSurfaces {
    static let shared = BrowserSurfaces()
    private var views: [String: HeedWebView] = [:]
    private var pages: [String: BrowserPage] = [:]
    private var observations: [String: [NSKeyValueObservation]] = [:]
    private lazy var delegate = BrowserDelegate(surfaces: self)

    /// A click in a page (the model focuses its pane and enters INSERT).
    var onPaneClick: ((String) -> Void)?
    /// A page went somewhere or got a title: pane, address, title.
    var onNavigated: ((String, String, String) -> Void)?
    /// A page asked for a new tab (a link with a target, ⌘-click): pane, address, whether to show it.
    var onOpenTab: ((String, URL, Bool) -> Void)?

    /// Safari's ⌘← and ⌘→: back and forward, unless you are typing in a field (there they move the caret).
    private static let historyKeys = """
    document.addEventListener('keydown', (e) => {
      if (!e.metaKey || e.altKey || e.ctrlKey || e.shiftKey) return;
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
      const el = document.activeElement;
      if (el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName))) return;
      e.preventDefault();
      if (e.key === 'ArrowLeft') history.back(); else history.forward();
    }, true);
    """

    func page(for pane: PaneSpec) -> BrowserPage {
        if let page = pages[pane.id] { return page }
        let page = BrowserPage(url: pane.url)
        page.title = pane.title
        pages[pane.id] = page
        return page
    }

    func view(for pane: PaneSpec) -> NSView {
        if let existing = views[pane.id] {
            existing.removeFromSuperview()
            return existing
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Without Safari's tokens some sites (Google sign-in) turn an embedded browser away.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.historyKeys, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        // Inspect Element in the page's menu. WebKit has no public switch for it; Safari's Develop menu works too.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let view = HeedWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = true
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        let paneID = pane.id
        view.onClick = { [weak self] in self?.onPaneClick?(paneID) }
        views[paneID] = view
        let start = page(for: pane).url
        observe(view, paneID: paneID)
        if !start.isEmpty, let url = URL(string: start) { view.load(URLRequest(url: url)) }
        return view
    }

    private func observe(_ view: WKWebView, paneID: String) {
        let sync: @Sendable () -> Void = { [weak self] in MainActor.assumeIsolated { self?.sync(paneID) } }
        observations[paneID] = [
            view.observe(\.url) { _, _ in sync() },
            view.observe(\.title) { _, _ in sync() },
            view.observe(\.isLoading) { _, _ in sync() },
            view.observe(\.estimatedProgress) { _, _ in sync() },
            view.observe(\.canGoBack) { _, _ in sync() },
            view.observe(\.canGoForward) { _, _ in sync() },
        ]
    }

    private func sync(_ paneID: String) {
        guard let view = views[paneID], let page = pages[paneID] else { return }
        let url = view.url?.absoluteString ?? page.url
        let title = view.title ?? ""
        let moved = url != page.url || title != page.title
        page.url = url
        page.title = title
        page.loading = view.isLoading
        page.progress = view.estimatedProgress
        page.canGoBack = view.canGoBack
        page.canGoForward = view.canGoForward
        if moved, !url.isEmpty { onNavigated?(paneID, url, title) }
    }

    /// A page started loading: what went wrong last time no longer applies.
    fileprivate func started(_ view: WKWebView) {
        guard let id = paneID(of: view), let page = pages[id] else { return }
        page.status = nil
        page.failure = nil
    }

    fileprivate func responded(_ view: WKWebView, status: Int) {
        guard let id = paneID(of: view) else { return }
        pages[id]?.status = status >= 400 ? status : nil
    }

    fileprivate func failed(_ view: WKWebView, _ error: Error) {
        let error = error as NSError
        // Cancelled (another load took over) and handed off (a download, another app) are not failures.
        let cancelled = error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
        let handedOff = error.domain == "WebKitErrorDomain" && error.code == 102
        guard !cancelled, !handedOff, let id = paneID(of: view) else { return }
        pages[id]?.failure = error.localizedDescription
    }

    func isBrowserView(_ view: NSView) -> Bool {
        views.values.contains { $0 === view }
    }

    fileprivate func paneID(of view: WKWebView) -> String? {
        views.first { $0.value === view }?.key
    }

    /// Loads `address` in the pane's page. A page whose web view is not made yet (its tab not drawn) keeps the
    /// address and loads it when it is.
    func load(_ address: String, paneID: String) {
        guard let url = URL(string: address) else { return }
        pages[paneID]?.url = address
        pages[paneID]?.failure = nil
        views[paneID]?.load(URLRequest(url: url))
    }

    func back(_ paneID: String) { views[paneID]?.goBack() }
    func forward(_ paneID: String) { views[paneID]?.goForward() }

    func reloadOrStop(_ paneID: String) {
        guard let view = views[paneID] else { return }
        if view.isLoading {
            view.stopLoading()
        } else if view.url == nil, let url = pages[paneID].flatMap({ URL(string: $0.url) }) {
            // Nothing loaded yet (the first load failed): try the address again.
            view.load(URLRequest(url: url))
        } else {
            view.reload()
        }
    }

    /// Multiplies the page's zoom by `factor`; nil is actual size.
    func zoom(_ paneID: String, by factor: Double?) {
        guard let view = views[paneID] else { return }
        view.pageZoom = factor.map { min(max(view.pageZoom * $0, 0.5), 3) } ?? 1
    }

    func address(of paneID: String) -> String? {
        views[paneID]?.url?.absoluteString ?? pages[paneID]?.url
    }

    /// A pane closed for good: its page goes, and with it its web content process.
    func close(paneID: String) {
        observations.removeValue(forKey: paneID)
        pages.removeValue(forKey: paneID)
        guard let view = views.removeValue(forKey: paneID) else { return }
        view.stopLoading()
        view.removeFromSuperview()
    }
}

/// A web view that says when it is clicked, as a terminal does, so a click into a page means typing there.
final class HeedWebView: WKWebView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }
}

/// Where pages may go. Links to other apps (mailto:, zoommtg:) open only from a click, never from a page on its own:
/// a page must not bring another app to the front.
@MainActor
private final class BrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var surfaces: BrowserSurfaces?
    private static let schemes: Set<String> = ["http", "https", "about", "file", "data", "blob"]

    init(surfaces: BrowserSurfaces) {
        self.surfaces = surfaces
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        let clicked = navigationAction.navigationType == .linkActivated
        if let scheme = url.scheme?.lowercased(), !Self.schemes.contains(scheme) {
            if clicked { NSWorkspace.shared.open(url) }
            return .cancel
        }
        if clicked, navigationAction.modifierFlags.contains(.command) {
            openTab(from: webView, url, show: false)
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            surfaces?.responded(webView, status: http.statusCode)
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        surfaces?.started(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        surfaces?.failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        surfaces?.failed(webView, error)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith _: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { openTab(from: webView, url, show: true) }
        return nil
    }

    /// The page's web content process died (a crash, memory pressure): load it again rather than leave it blank.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func openTab(from webView: WKWebView, _ url: URL, show: Bool) {
        guard let surfaces, let paneID = surfaces.paneID(of: webView) else { return }
        surfaces.onOpenTab?(paneID, url, show)
    }
}
