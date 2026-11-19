import Foundation
@testable import HeedCore
import ImageIO
import Testing
import UniformTypeIdentifiers

struct FileViewerTests {
    @Test func imagesAreKnownByTheirExtension() {
        for path in [
            "/tmp/a.png", "/tmp/b.JPG", "/tmp/c.jpeg", "/tmp/d.gif", "/tmp/e.webp", "/tmp/f.heic", "/tmp/g.tiff",
        ] {
            #expect(FileViewer.kind(of: path) == .image, "\(path)")
        }
    }

    @Test func otherFilesHaveNoViewer() {
        for path in [
            "/tmp/a.ts", "/tmp/b.md", "/tmp/c", "/tmp/d.json", "/tmp/e.pdf", "/tmp/f.mov", "/tmp/.png/x", "/tmp/g.svg",
        ] {
            #expect(FileViewer.kind(of: path) == nil, "\(path)")
        }
    }

    @Test func readsAnImageWithItsPixelSize() throws {
        let path = try temporaryPNG(width: 30, height: 20)
        guard case let .image(file) = FileViewer.read(path) else {
            Issue.record("not read as an image")
            return
        }
        #expect(file.pixelWidth == 30)
        #expect(file.pixelHeight == 20)
        #expect(file.pointSize == CGSize(width: 30, height: 20))
        #expect(file.modified != nil)
    }

    @Test func anUnchangedFileReadsTheSame() throws {
        let path = try temporaryPNG(width: 4, height: 4)
        #expect(FileViewer.read(path) == FileViewer.read(path))
    }

    @Test func aMissingFileIsMissing() {
        #expect(FileViewer.read("/tmp/heed-no-such-\(UUID().uuidString).png") == .missing)
    }

    @Test func aFolderOrNonImageIsUnreadable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heed-viewer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(FileViewer.read(folder.path) == .unreadable)
        let text = folder.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: text)
        #expect(FileViewer.read(text.path) == .unreadable)
    }

    private func temporaryPNG(width: Int, height: Int) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-viewer-\(UUID().uuidString).png")
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url.path
    }
}

struct ViewerLayoutTests {
    private func agentAndWork() -> TaskLayout {
        let agent = PaneTab(title: "agent", pane: PaneSpec(id: "agent", role: .agent, title: "claude", directory: "/w"))
        let shell = PaneTab(title: "zsh", pane: PaneSpec(id: "shell", role: .shell, title: "zsh", directory: "/w"))
        let page = PaneTab(title: "page", pane: PaneSpec(id: "page", role: .browser, title: "", directory: "/w"))
        return TaskLayout(
            root: .split(
                .horizontal, .leaf(PaneGroup(id: "left", tabs: [agent])),
                .leaf(PaneGroup(id: "right", tabs: [shell, page])), ratio: 0.5
            ),
            focusedGroup: "left"
        )
    }

    @Test func theViewerRoleIsNotATerminalAndSurvivesTheCache() throws {
        let pane = PaneSpec(id: "v1", role: .viewer, title: "a.png", directory: "/w", path: "/tmp/a.png")
        #expect(!pane.role.isTerminal)
        let decoded = try JSONDecoder().decode(PaneSpec.self, from: JSONEncoder().encode(pane))
        #expect(decoded == pane)
    }

    @Test func anImageOpensInTheWorkPaneNextToTheTerminalClicked() {
        var layout = agentAndWork()
        let viewer = layout.showViewer(path: "/tmp/shot.png", directory: "/w", nextTo: "shell", show: true)
        #expect(viewer.role == .viewer)
        #expect(viewer.title == "shot.png")
        let right = layout.group("right")
        #expect(right?.tabs.map(\.pane.id) == ["shell", viewer.id, "page"])
        #expect(layout.focusedPane?.id == viewer.id)
    }

    @Test func fromTheAgentItOpensInTheWorkPaneNotBesideTheAgent() {
        var layout = agentAndWork()
        let viewer = layout.showViewer(path: "/tmp/shot.png", directory: "/w", nextTo: "agent", show: true)
        #expect(layout.group(ofPane: viewer.id)?.id == "right")
        #expect(layout.group("left")?.tabs.count == 1)
    }

    @Test func theSameImageAgainGoesToItsTab() {
        var layout = agentAndWork()
        let first = layout.showViewer(path: "/tmp/shot.png", directory: "/w", show: true)
        layout.focus(pane: "agent")
        let again = layout.showViewer(path: "/tmp/shot.png", directory: "/w", show: true)
        #expect(again.id == first.id)
        #expect(layout.panes.count { $0.role == .viewer } == 1)
        #expect(layout.focusedPane?.id == first.id)
    }

    @Test func differentImagesOpenTabsOfTheirOwn() {
        var layout = agentAndWork()
        layout.showViewer(path: "/tmp/a.png", directory: "/w", show: true)
        layout.showViewer(path: "/tmp/b.png", directory: "/w", show: true)
        #expect(layout.panes.filter { $0.role == .viewer }.map(\.path) == ["/tmp/a.png", "/tmp/b.png"])
    }

    @Test func theFixtureShowsAViewerTab() {
        let layout = Fixtures.tasks.layouts["t3"]
        #expect(layout?.viewerPane(path: Fixtures.viewerImage) != nil)
    }
}
