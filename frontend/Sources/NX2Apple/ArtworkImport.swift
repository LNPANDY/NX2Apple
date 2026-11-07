import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A chosen image turned into the copy the app keeps: validated by its content, downscaled to what its slot can show,
/// and stored under a name made from its bytes. The original is only read, so moving or deleting it changes nothing.
/// Pure and safe to call from any thread.
enum ArtworkImport {
    enum Kind {
        case hero, thumbnail

        var maxWidth: Int {
            switch self {
            case .hero: return 3840
            case .thumbnail: return 1920
            }
        }
        /// Narrower than this is drawn soft: worth a warning, never a refusal.
        var lowResolutionWidth: Int {
            switch self {
            case .hero: return 1920
            case .thumbnail: return 640
            }
        }
    }

    enum Failure: Error {
        case notAnImage, tooLarge, unreadable

        var messageKey: String {
            switch self {
            case .notAnImage: return "artwork.error.notImage"
            case .tooLarge: return "artwork.error.tooLarge"
            case .unreadable: return "artwork.error.unreadable"
            }
        }
    }

    struct Prepared {
        let url: URL
        let pixelSize: CGSize
        let lowResolution: Bool
    }

    static let maxFileSize = 50 << 20
    private static let acceptedTypes: Set<String> = ["public.png", "public.jpeg", "public.heic", "org.webmproject.webp", "public.tiff"]

    static func prepare(_ url: URL, kind: Kind, into directory: URL) throws -> Prepared {
        // The size first: nothing of a huge file is read.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileSize { throw Failure.tooLarge }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw Failure.unreadable }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?, acceptedTypes.contains(type) else { throw Failure.notAnImage }
        guard CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int, let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              rawWidth > 0, rawHeight > 0 else { throw Failure.unreadable }
        // Orientations 5 to 8 turn the image on its side: the width that counts is the upright one.
        let turned = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        let width = Double(turned ? rawHeight : rawWidth), height = Double(turned ? rawWidth : rawHeight)

        // ImageIO limits the longer side.
        let scale = min(1, Double(kind.maxWidth) / width)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int((max(width, height) * scale).rounded())),   // never enlarged
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw Failure.unreadable }   // a cut-off file decodes in part

        let image = try stored(decoded)
        let lowResolution = image.width < kind.lowResolutionWidth
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.unreadable }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }

        let name = SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined() + ".jpg"
        let stored = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: stored.path) {   // the same image again is the same file
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (data as Data).write(to: stored, options: .atomic)   // a temporary file beside it, then a move
        }
        return Prepared(url: stored, pixelSize: CGSize(width: image.width, height: image.height), lowResolution: lowResolution)
    }

    /// The pixels as they are stored: anything with transparency laid on black (JPEG has none), the rest as decoded.
    private static func stored(_ decoded: CGImage) throws -> CGImage {
        let opaque: Set<CGImageAlphaInfo> = [.none, .noneSkipFirst, .noneSkipLast]
        if opaque.contains(decoded.alphaInfo) { return decoded }
        let size = CGSize(width: decoded.width, height: decoded.height)
        guard let context = CGContext(data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.unreadable }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        context.draw(decoded, in: CGRect(origin: .zero, size: size))
        guard let image = context.makeImage() else { throw Failure.unreadable }
        return image
    }
}
