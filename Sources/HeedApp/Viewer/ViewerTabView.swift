import AppKit
import HeedCore
import SwiftUI

/// A Viewer tab: the file's name in a header, then the file as it looks. Only images so far (`FileViewer.Kind`).
struct ViewerTabView: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let active: Bool

    var body: some View {
        VStack(spacing: 0) {
            ViewerHeader(pane: pane, active: active, read: model.viewerFiles[pane.id])
            ViewerBody(pane: pane, read: model.viewerFiles[pane.id])
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .background(Theme.pane)
        .onAppear { model.viewerTabShown(pane.id) }
    }
}

private struct ViewerHeader: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let active: Bool
    let read: FileViewer.Read?

    var body: some View {
        HStack(spacing: 10) {
            Text(pane.title)
                .font(Theme.ui(12, weight: .semibold))
                .foregroundStyle(active ? Theme.fg : Theme.fg2)
                .lineLimit(1)
                .truncationMode(.middle)
            if case let .image(file) = read {
                Text(verbatim: "\(file.pixelWidth) × \(file.pixelHeight)").font(Theme.mono(11))
                    .foregroundStyle(Theme.fg3).fixedSize()
            }
            Spacer(minLength: 8)
            if let key = model.keyLabel(for: "viewer.reload") {
                KeyCap(text: key)
                Text("reload").font(Theme.ui(11)).foregroundStyle(Theme.fg3).fixedSize()
            }
            if let key = model.keyLabel(for: "viewer.open") {
                KeyCap(text: key)
                Text("open").font(Theme.ui(11)).foregroundStyle(Theme.fg3).fixedSize()
            }
        }
        .help(pane.path.map(Paths.abbreviate) ?? "")
        .font(Theme.ui(11.5))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .clipped()
        .background(Theme.paneHeader)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

private struct ViewerBody: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let read: FileViewer.Read?

    var body: some View {
        Group {
            switch read {
            case nil:
                Theme.pane
            case let .image(file):
                // Fitted to the tab, never larger than the file's own size.
                Image(decorative: file.image, scale: file.scale)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: file.pointSize.width, maxHeight: file.pointSize.height)
                    .padding(16)
            case .missing:
                message(
                    "The file is gone",
                    "macOS clears /tmp when it restarts, and drops files there that are a few days old."
                )
            case .unreadable:
                message("Heed can't read this image", openHint)
            case let .tooBig(bytes):
                message("Too big to show here (\(bytes / 1_048_576) MB)", openHint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var openHint: String {
        model.keyLabel(for: "viewer.open").map { "\($0) opens it in its app." } ?? "Open it in its app."
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.fg2)
            if let path = pane.path {
                Text(Paths.abbreviate(path)).font(Theme.mono(11)).foregroundStyle(Theme.fg3).textSelection(.enabled)
            }
            Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }
}

private extension ImageFile {
    /// Pixels per point.
    var scale: CGFloat { pointSize.width > 0 ? CGFloat(pixelWidth) / pointSize.width : 1 }
}

/// The fixtures' image (`Fixtures.viewerImage`), drawn here: fixtures read no files. A retina screenshot of a chat
/// with the message the review's agent found the freeze at circled, as an agent marks one up.
@MainActor
enum ViewerStill {
    static let image: ImageFile = draw()

    private static func draw() -> ImageFile {
        let size = CGSize(width: 600, height: 380)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        drawChat(in: size)
        NSGraphicsContext.restoreGraphicsState()
        return ImageFile(image: rep.cgImage!, pointSize: size, bytes: 0, modified: nil)
    }

    private static func drawChat(in size: CGSize) {
        func fill(_ rect: CGRect, _ hex: Int, radius: CGFloat = 0) {
            color(hex).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, _ hex: Int) {
            (string as NSString).draw(at: point, withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(hex),
            ])
        }
        fill(CGRect(origin: .zero, size: size), 0xF7F8FC)
        fill(CGRect(x: 0, y: 0, width: size.width, height: 40), 0xFFFFFF)
        fill(CGRect(x: 0, y: 40, width: size.width, height: 1), 0xD3DAE6)
        text("Agent Builder", at: CGPoint(x: 18, y: 12), size: 13, weight: .semibold, 0x1A1C21)
        text("Conversation · 214 messages", at: CGPoint(x: 120, y: 13), size: 12, 0x69707D)
        let rows: [(String, Bool)] = [
            ("Summarise the last deploy's errors", true), ("Found 12 errors in 3 services. The most…", false),
            ("Show the ones from the checkout service", true), ("Here are the 5 checkout errors, grouped…", false),
            ("Draw them on a timeline", true),
        ]
        for (index, row) in rows.enumerated() {
            let y = 58 + CGFloat(index) * 52
            let width: CGFloat = row.1 ? 300 : 420
            let x: CGFloat = row.1 ? size.width - width - 24 : 24
            fill(CGRect(x: x, y: y, width: width, height: 38), row.1 ? 0xE6F1FA : 0xFFFFFF, radius: 8)
            text(row.0, at: CGPoint(x: x + 12, y: y + 11), size: 12, 0x343741)
        }
        let ring = NSBezierPath(ovalIn: CGRect(x: 268, y: 260, width: 316, height: 66))
        ring.lineWidth = 3
        color(0xE7664C).setStroke()
        ring.stroke()
        text("freezes here: 214 rows re-render", at: CGPoint(x: 330, y: 338), size: 13, weight: .semibold, 0xBD271E)
    }

    private static func color(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}
