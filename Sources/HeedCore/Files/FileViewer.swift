import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The files a Viewer tab shows, and reading one. Only images for now; another kind (a PDF, a video) is a new case
/// here and a new view in the tab.
public enum FileViewer {
    public enum Kind: String, Sendable, Hashable {
        case image
    }

    /// What a Viewer tab shows for `path`, by its extension; nil when it has nothing to show it with (an SVG is an
    /// image ImageIO can't read).
    public static func kind(of path: String) -> Kind? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        return type.conforms(to: .image) && imageTypes.contains(type.identifier) ? .image : nil
    }

    private static let imageTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])

    /// Files larger than this are not read: `e` still opens them in their app.
    public static let maxBytes = 50 * 1024 * 1024

    public enum Read: Sendable, Equatable {
        case image(ImageFile)
        case missing
        /// A folder, or not an image ImageIO can read.
        case unreadable
        case tooBig(bytes: Int)
    }

    /// Reads and decodes `path`. Blocking: call it off the main actor.
    public static func read(_ path: String) -> Read {
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &folder) else { return .missing }
        guard !folder.boolValue else { return .unreadable }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard bytes <= maxBytes else { return .tooBig(bytes: bytes) }
        guard let data = FileManager.default.contents(atPath: path) else { return .unreadable }
        return ImageFile(data: data, modified: attributes?[.modificationDate] as? Date).map(Read.image) ?? .unreadable
    }
}

/// An image file, decoded: drawing it never decodes on the main actor. Two reads are equal when the file didn't
/// change (same size on disk, same modification time, same pixels), so a read again redraws nothing.
public struct ImageFile: @unchecked Sendable, Equatable {
    /// Immutable, so safe to hand across actors.
    public let image: CGImage
    /// The pixels at the file's DPI: a retina screenshot (144 dpi) shows at the size it was taken.
    public let pointSize: CGSize
    public let bytes: Int
    public let modified: Date?

    public var pixelWidth: Int { image.width }
    public var pixelHeight: Int { image.height }

    public init(image: CGImage, pointSize: CGSize, bytes: Int, modified: Date?) {
        self.image = image
        self.pointSize = pointSize
        self.bytes = bytes
        self.modified = modified
    }

    /// Nil when ImageIO cannot read `data` as an image. Turned as its EXIF orientation says.
    public init?(data: Data, modified: Date? = nil) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = dpi > 0 ? 72 / dpi : 1
        self.init(
            image: image, pointSize: CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale),
            bytes: data.count, modified: modified
        )
    }

    public static func == (lhs: ImageFile, rhs: ImageFile) -> Bool {
        lhs.bytes == rhs.bytes && lhs.modified == rhs.modified && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
    }
}
