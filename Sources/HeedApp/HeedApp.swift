import AppKit
import HeedCore
import SwiftUI

@main
struct HeedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        LaunchGuard.check()
    }

    var body: some Scene {
        Window("Heed", id: "main") {
            HostedMainWindow(host: delegate.host)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { delegate.windowAppeared() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            // Keys are the mode engine's; the menu must not claim ⌘/ or other keys before it sees them.
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `HEED_FIXTURE=<name>` (or a snapshot run) opens on a fixture domain with no IO at all; otherwise the cached
    /// domain loads in the background and git refreshes it.
    let model: AppModel = {
        // Before the model reads its preferences.
        LegacyDefaults.migrate()
        let environment = ProcessInfo.processInfo.environment
        let fixture = environment["HEED_FIXTURE"] ?? (environment["HEED_SNAPSHOT"] != nil ? "tasks" : nil)
        let base = switch fixture {
        case "resume": "tasks"
        case "firstrun": "empty"
        default: fixture
        }
        if let fixture, let base, let domain = Fixtures.named(base) {
            Paths.home = Fixtures.home
            let model = AppModel(domain: domain, isFixture: true)
            if fixture == "resume" { model.showResumeForFixture() }
            if fixture == "firstrun" {
                model.showFirstRun(report: FirstRunReport(githubUser: "you", agents: [
                    .init(name: "claude", path: "/Users/you/.local/bin/claude"),
                ]))
            }
            return model
        }
        return AppModel(domain: .empty, isFixture: false)
    }()

    /// What the window shows.
    lazy var host = ModelHost(live: model)

    private lazy var router = KeyRouter(host: host)

    func applicationDidFinishLaunching(_: Notification) {
        // Heed's palette is dark only. Without this, anything left to the system colours (a Text with no style, native
        // controls, Settings) follows macOS and turns black on the dark panels in light mode.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // HEED_SHOTS: render the docs' screenshots from the fake world, then quit; nothing else starts.
        if ShotRunner.requested {
            NSApp.setActivationPolicy(.accessory)
            Task {
                await ShotRunner.run()
                exit(0)
            }
            return
        }
        // No NSApp.activate(): Heed never takes focus, it only asks for attention.
        NSApp.setActivationPolicy(.regular)
        router.start()
        if !model.isFixture {
            Task { await model.start(cache: DomainStore.defaultFile()) }
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        // Fixtures quit at once, unless HEED_OUTSIDE has them behave like the live app outside the window.
        let outside = ProcessInfo.processInfo.environment["HEED_OUTSIDE"] != nil
        guard !model.isFixture || outside else { return .terminateNow }
        // Quitting stops every agent: with any of them running, ask first (the confirm quits again when accepted).
        guard model.quitConfirmed || !model.confirmQuitIfAgentsRun() else { return .terminateCancel }
        // From here terminals ending are the quit, not exits: sessions keep their panes for the next launch.
        model.beginTerminating()
        Task {
            await model.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowAppeared() {
        // The window exists but may not be on screen yet when its content appears; it is the app's only window.
        guard let window = NSApp.windows.first(where: { $0.identifier == AppModel.mainWindowID })
            ?? NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })
            ?? NSApp.windows.first
        else { return }
        window.identifier = AppModel.mainWindowID
        window.backgroundColor = NSColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        Snapshot.runIfRequested(window: window, host: host)
    }

    /// With the menu bar item, closing the window leaves Heed (and every agent in it) running; Open Heed or the
    /// activate shortcut brings it back. Without it, closing the window quits as before.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        model.isFixture || !model.config.showMenuBarItem
    }
}

/// Which model the main window, the keys and pane clicks belong to.
@MainActor
@Observable
final class ModelHost {
    let live: AppModel
    var current: AppModel {
        didSet { wire() }
    }

    init(live: AppModel) {
        self.live = live
        current = live
        wire()
    }

    private func wire() {
        let model = current
        TerminalSurfaces.shared.onPaneClick = { [weak model] paneID in model?.clickedPane(paneID) }
        TerminalSurfaces.shared.onPaneExited = { [weak model] paneID in model?.paneExited(paneID) }
        TerminalSurfaces.shared.onPaneOpenURL = { [weak model] paneID, url in model?.openLink(url, fromPane: paneID) }
        BrowserSurfaces.shared.onPaneClick = { [weak model] paneID in model?.clickedPane(paneID) }
        BrowserSurfaces.shared.onNavigated = { [weak model] paneID, url, title in
            model?.pageChanged(paneID, url: url, title: title)
        }
        BrowserSurfaces.shared.onOpenTab = { [weak model] paneID, url, show in
            model?.openPageTab(from: paneID, url: url.absoluteString, show: show)
        }
    }
}

/// The main window for whichever model the host holds.
struct HostedMainWindow: View {
    let host: ModelHost

    var body: some View {
        MainWindow().environment(host.current)
            // Links in rendered text (an issue's body) open as pages too.
            .environment(\.openURL, OpenURLAction { [host] url in
                host.current.openLink(url.absoluteString, from: host.current.linkSource)
                return .handled
            })
    }
}
