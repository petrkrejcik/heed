import AppKit
import SwiftUI

/// A strip on a divider or a column's edge that resizes by dragging. It reports how far the mouse has moved since the
/// press (right and down are positive), then `ended` with the last distance once the button is let go.
struct ResizeHandle: NSViewRepresentable {
    /// `.horizontal`: dragged sideways (a column's edge, a side-by-side split); `.vertical`: up and down.
    let axis: Axis
    let moved: (CGFloat) -> Void
    let ended: (CGFloat) -> Void

    func makeNSView(context _: Context) -> ResizeHandleView {
        ResizeHandleView()
    }

    func updateNSView(_ view: ResizeHandleView, context _: Context) {
        view.axis = axis
        view.moved = moved
        view.ended = ended
        view.window?.invalidateCursorRects(for: view)
    }
}

/// A side column's edge: dragging it resizes the column from the width it had when the drag began. `resize` gets the
/// new width and whether the mouse was let go.
struct ColumnEdge: View {
    let width: Double
    /// The inspector's edge is on its left: dragging left makes it wider.
    var growsLeft = false
    let resize: (Double, Bool) -> Void
    @State private var start: Double?

    var body: some View {
        ResizeHandle(
            axis: .horizontal,
            moved: { distance in
                if start == nil { start = width }
                resize((start ?? width) + (growsLeft ? -distance : distance), false)
            },
            ended: { distance in
                resize((start ?? width) + (growsLeft ? -distance : distance), true)
                start = nil
            }
        )
        .frame(width: 7)
    }
}

/// The handle's AppKit side. The key router's click monitor treats it as part of the panes, so dragging a divider
/// doesn't leave INSERT.
final class ResizeHandleView: NSView {
    var axis: Axis = .horizontal
    var moved: (CGFloat) -> Void = { _ in }
    var ended: (CGFloat) -> Void = { _ in }
    private var start: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        moved(distance(to: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        ended(distance(to: event))
        start = nil
    }

    /// Window coordinates grow upwards; a drag down is positive here, as in SwiftUI.
    private func distance(to event: NSEvent) -> CGFloat {
        guard let start else { return 0 }
        let now = event.locationInWindow
        return axis == .horizontal ? now.x - start.x : start.y - now.y
    }
}
