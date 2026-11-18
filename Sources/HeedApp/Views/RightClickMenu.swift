import AppKit
import HeedCore
import SwiftUI

extension View {
    /// A right-click (or ⌃-click) menu over this view. `prepare` runs first and targets the clicked thing (selects its
    /// row, as a click does); false means clicks do not reach lists now (a dialog is up) and no menu opens. The entries
    /// are built after it, so they describe the world as it is when the menu opens.
    ///
    /// AppKit's menu, not SwiftUI's `.contextMenu`: SwiftUI can only show a key as a key equivalent, and Heed's keys
    /// are sequences (`dd`, `⌃w c`) that none can hold. Each key is drawn as text on a right tab stop instead.
    func rightClickMenu(prepare: @escaping () -> Bool, _ entries: @escaping () -> [MenuEntry]) -> some View {
        overlay {
            // The docs' offscreen renderer draws no AppKit views.
            if !ShotMode.active { RightClickArea(prepare: prepare, entries: entries) }
        }
    }
}

/// An invisible AppKit view over the SwiftUI one that takes only the right-click: every other event passes through it
/// (`hitTest` answers nil), so taps, double-clicks, hover and scrolling behave as before.
private struct RightClickArea: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let prepare: () -> Bool
    let entries: () -> [MenuEntry]

    func makeNSView(context _: Context) -> AreaView { AreaView() }

    func updateNSView(_ view: AreaView, context _: Context) {
        view.model = model
        view.prepare = prepare
        view.entries = entries
    }

    final class AreaView: NSView {
        weak var model: AppModel?
        var prepare: () -> Bool = { false }
        var entries: () -> [MenuEntry] = { [] }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.opensMenu(event) else { return nil }
            return super.hitTest(point)
        }

        static func opensMenu(_ event: NSEvent) -> Bool {
            event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }

        override func rightMouseDown(with event: NSEvent) { show(event) }
        /// Only a ⌃-click gets here (see `hitTest`).
        override func mouseDown(with event: NSEvent) { show(event) }

        private func show(_ event: NSEvent) {
            guard let model, prepare() else { return }
            let entries = entries()
            guard !entries.isEmpty else { return }
            NSMenu.popUpContextMenu(RightClickMenu.menu(entries, model: model), with: event, for: self)
        }
    }
}

/// The NSMenu for a list of entries: each item runs its command through the model, its key on the right.
@MainActor
enum RightClickMenu {
    static func menu(_ entries: [MenuEntry], title: String = "", model: AppModel) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        let font = NSFont.menuFont(ofSize: 0)
        let items = entries.compactMap { if case let .item(item) = $0 { item } else { nil } }
        // One tab stop for the whole menu, past its widest title, so the keys line up as shortcuts do.
        let widest = items.map { width($0.title, font) }.max() ?? 0
        let widestKey = items.map { width(model.menuKey(for: $0), font) }.max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: widest + 36 + widestKey)]
        for entry in entries {
            switch entry {
            case let .header(title):
                menu.addItem(.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            case let .item(item):
                let menuItem = Self.item(item, model: model)
                menuItem.attributedTitle = attributedTitle(
                    item.title, key: model.menuKey(for: item), enabled: item.enabled, font: font, paragraph: paragraph
                )
                menu.addItem(menuItem)
            case let .submenu(title, entries):
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                parent.submenu = Self.menu(entries, title: title, model: model)
                menu.addItem(parent)
            }
        }
        return menu
    }

    /// One item that runs its command through the model.
    private static func item(_ item: MenuItem, model: AppModel) -> NSMenuItem {
        let action = Action { model.perform(item.command) }
        let menuItem = NSMenuItem(title: item.title, action: #selector(Action.run), keyEquivalent: "")
        menuItem.target = action
        // The target is weak; the item keeps the action alive.
        menuItem.representedObject = action
        menuItem.isEnabled = item.enabled
        menuItem.state = item.checked ? .on : .off
        return menuItem
    }

    /// `Done…⇥dd`: the title as AppKit draws it (an attributed title is not greyed when disabled, so that is done
    /// here), the key in the secondary colour.
    private static func attributedTitle(
        _ title: String, key: String, enabled: Bool, font: NSFont, paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        var base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        if !enabled { base[.foregroundColor] = NSColor.disabledControlTextColor }
        let text = NSMutableAttributedString(string: title, attributes: base)
        var keyAttributes = base
        keyAttributes[.foregroundColor] = enabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        text.append(NSAttributedString(string: "\t\(key)", attributes: keyAttributes))
        return text
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private final class Action: NSObject {
        let perform: () -> Void

        init(_ perform: @escaping () -> Void) { self.perform = perform }

        @objc func run() { perform() }
    }
}
