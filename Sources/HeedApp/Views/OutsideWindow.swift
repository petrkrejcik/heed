import AppKit
import HeedCore
import SwiftUI

/// What needs you, as shown outside Heed's window: the Dock badge and the menu bar item read the same counts.
struct Attention: Equatable {
    var blocked: Int
    var asking: Int

    var total: Int { blocked + asking }
    /// Blocked outranks asking: an agent that cannot go on at all comes first.
    var color: NSColor? {
        blocked > 0 ? NSColor(Theme.block) : asking > 0 ? NSColor(Theme.ask) : nil
    }
}

/// The Dock icon with live state (`[ui] dock_state`): the app icon, plus a badge in the state's colour with how many
/// tasks need you. Plain icon when nothing does.
@MainActor
enum DockState {
    private static var shown: Attention?

    static func update(_ attention: Attention, enabled: Bool) {
        let tile = NSApp.dockTile
        guard enabled, attention.total > 0 else {
            if shown != nil || tile.contentView != nil {
                tile.contentView = nil
                tile.badgeLabel = nil
                tile.display()
            }
            shown = nil
            return
        }
        guard attention != shown else { return }
        shown = attention
        let view = BadgedIconView(frame: NSRect(origin: .zero, size: tile.size))
        view.attention = attention
        tile.contentView = view
        tile.display()
    }

    /// The badged icon as an image (the docs' screenshots draw this).
    static func image(_ attention: Attention, side: CGFloat) -> NSImage {
        let view = BadgedIconView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.attention = attention
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private final class BadgedIconView: NSView {
        var attention = Attention(blocked: 0, asking: 0)

        override func draw(_: NSRect) {
            NSApp.applicationIconImage?.draw(in: bounds)
            guard let color = attention.color else { return }
            // A badge in the bottom right, the size macOS uses for its own (about a third of the tile).
            let side = bounds.width * 0.36
            let badge = NSRect(
                x: bounds.maxX - side - bounds.width * 0.02,
                y: bounds.minY + bounds.width * 0.02,
                width: side,
                height: side
            )
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: -side * 0.04, dy: -side * 0.04)).fill()
            color.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let text = attention.total > 9 ? "9+" : "\(attention.total)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: side * 0.58, weight: .bold),
                .foregroundColor: NSColor(red: 0.055, green: 0.059, blue: 0.067, alpha: 1),
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}

/// The menu bar item (`[ui] menu_bar`): the mono owl, with the count beside it when tasks need you. Its menu lists
/// those tasks (choosing one opens Heed on it), then Open Heed, Settings and Quit.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    static let shared = MenuBarItem()

    private var item: NSStatusItem?
    private weak var model: AppModel?
    private var shown: Attention?

    func update(model: AppModel, attention: Attention, enabled: Bool) {
        self.model = model
        guard enabled else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shown = nil
            return
        }
        let item = item ?? makeItem()
        self.item = item
        guard attention != shown else { return }
        shown = attention
        item.button?.title = attention.total > 0 ? " \(attention.total)" : ""
        item.button?.toolTip = attention.total > 0
            ? "Heed: \(attention.total) task\(attention.total == 1 ? "" : "s") need\(attention.total == 1 ? "s" : "") you"
            : "Heed"
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.main.url(forResource: "menubar", withExtension: "svg"),
           let image = NSImage(contentsOf: url)
        {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true // follows the menu bar's light or dark look
            item.button?.image = image
            item.button?.imagePosition = .imageLeading
        } else {
            item.button?.title = "heed"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        return item
    }

    /// One line of the menu: what the real menu shows and the screenshots draw. Nil is a separator.
    struct Entry {
        enum Action { case none, openTask(String), openHeed, settings, quit }
        var title: String
        var action: Action = .none
        var shortcut = ""
        var dot: Color?
    }

    static func entries(for model: AppModel) -> [Entry?] {
        var entries: [Entry?] = []
        let list = model.list
        let waiting = list.all.compactMap { task -> (WorkTask, AgentState)? in
            guard let state = list.rollup(of: task.id).agent?.state, [.blocked, .asking].contains(state) else {
                return nil
            }
            return (task, state)
        }
        if waiting.isEmpty {
            entries.append(Entry(title: "Nothing needs you"))
        } else {
            entries.append(Entry(title: "\(waiting.count) need\(waiting.count == 1 ? "s" : "") you"))
            for (task, state) in waiting {
                entries.append(Entry(
                    title: "\(task.title) · \(state.rawValue)", action: .openTask(task.id),
                    dot: state == .blocked ? Theme.block : Theme.ask
                ))
            }
        }
        let working = list.all.count { list.rollup(of: $0.id).agent?.state == .working }
        if working > 0 { entries.append(Entry(title: "\(working) working")) }
        entries.append(nil)
        entries.append(Entry(title: "Open Heed", action: .openHeed, shortcut: model.config.globalActivate))
        entries.append(nil)
        entries.append(Entry(title: "Settings…", action: .settings))
        entries.append(Entry(title: "Quit Heed", action: .quit))
        return entries
    }

    /// Built each time it opens, so it is never stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        for entry in Self.entries(for: model) {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let selector: Selector? = switch entry.action {
            case .none: nil
            case .openTask: #selector(openTask(_:))
            case .openHeed: #selector(openHeed)
            case .settings: #selector(openSettings)
            case .quit: #selector(quit)
            }
            guard let selector else {
                menu.addItem(disabled: entry.title)
                continue
            }
            menu.addItem(action: entry.title, selector, shortcut: entry.shortcut, target: self)
            if case let .openTask(id) = entry.action { menu.items.last?.representedObject = id }
            if let color = entry.dot { menu.items.last?.image = dot(NSColor(color)) }
        }
    }

    @objc private func openTask(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model?.show(taskID: id)
    }

    @objc private func openHeed() { model?.activateHeed() }
    @objc private func openSettings() {
        model?.activateHeed()
        model?.openSettings?()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    /// An item showing its global shortcut on the right, as text: these are system-wide keys, not menu equivalents.
    func addItem(action title: String, _ selector: Selector, shortcut: String, target: AnyObject) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        if !shortcut.isEmpty {
            let label = NSMutableAttributedString(string: title)
            label.append(NSAttributedString(
                string: "    \(KeyCapText.of(shortcut))",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            ))
            item.attributedTitle = label
        }
        addItem(item)
    }
}
