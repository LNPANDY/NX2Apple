import Foundation
import ImageIO
import CoreGraphics

/// What Change artwork may point at, and what an install copies into the phone app.
/// A movie is copied as itself. ImageIO reads a still or a GIF (and an animated WebP or APNG) frame by frame.
package enum CoverFile {
    /// Extensions the shell library looks for, in the order it tries them. The install deletes every one of these before it writes the new banner.
    package static let shellExtensions = ["png", "jpg", "jpeg", "heic", "webp", "gif", "mp4", "mov", "m4v"]
    package static let movieExtensions: Set<String> = ["mp4", "mov", "m4v"]

    package static func ext(_ path: String) -> String {
        (path as NSString).pathExtension.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    package static func isMovie(_ path: String) -> Bool { movieExtensions.contains(ext(path)) }

    package struct Frame {
        package let image: CGImage
        package let seconds: Double
    }

    /// A cover copied into the phone app. A larger file is a film, not a tile.
    package static let maxBytes: Int64 = 64 * 1024 * 1024

    /// False when the file is missing or larger than `max`.
    package static func withinLimit(_ path: String, max: Int64 = maxBytes, fm: FileManager = .default) -> Bool {
        guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber else { return false }
        return size.int64Value >= 0 && size.int64Value <= max
    }

    /// Empty when the path is a movie or ImageIO cannot read it.
    /// Each frame is the whole picture, then scaled. A thumbnail of a GIF is only the part that changed, so it is not used.
    /// A tile never needs a full-size frame, and a long GIF of full-size frames will not fit in memory.
    package static func frames(at path: String) -> [Frame] {
        guard !path.isEmpty, !isMovie(path),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return [] }
        let count = CGImageSourceGetCount(src)
        let maxPixel = count > 24 ? 960 : 1280
        var out: [Frame] = []
        for i in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(src, i, [kCGImageSourceShouldCache: false] as CFDictionary) else { continue }
            out.append(Frame(image: fitted(image, maxPixel: maxPixel), seconds: delay(src, i)))
        }
        return out
    }

    /// The longer side is at most `maxPixel`. A picture that is already smaller is returned as it is.
    private static func fitted(_ image: CGImage, maxPixel: Int) -> CGImage {
        let width = image.width, height = image.height
        let longest = max(width, height)
        if longest <= maxPixel || longest == 0 { return image }
        let scale = Double(maxPixel) / Double(longest)
        let wide = max(1, Int((Double(width) * scale).rounded()))
        let high = max(1, Int((Double(height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: wide, height: high))
        return context.makeImage() ?? image
    }

    /// The first picture only. A still tile uses this, so opening a GIF does not decode every frame.
    /// A GIF stays on the full frame. A thumbnail of a GIF is only the part that changed.
    /// A still uses a thumbnail so an orientation tag is applied and a huge picture is scaled down.
    package static func poster(at path: String) -> CGImage? {
        guard !path.isEmpty, !isMovie(path),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        if ext(path) == "gif" {
            return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1280,
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// A GIF, an animated WebP or APNG, or a silent movie that is on disk and small enough to be a cover.
    /// A still returns false, including an empty path, a missing file, and a file over the size limit.
    /// JPEG, HEIC and TIFF are one picture, so they are not opened.
    package static func animates(_ path: String) -> Bool {
        if path.isEmpty || !withinLimit(path) { return false }
        if isMovie(path) { return true }
        let kind = ext(path)
        guard kind == "gif" || kind == "webp" || kind == "png" else { return false }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    /// GIF, WebP and APNG delays of 0 mean "as fast as you like". 0.1s is the usual stand-in, and the floor for a missing delay.
    private static func delay(_ src: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] else { return 0.1 }
        if let gif = frameDelay(props, kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime) {
            // Two centiseconds is the fastest a GIF is meant to run. One, or zero, is stored as "as fast as you like".
            let centiseconds = Int((gif * 100).rounded())
            return centiseconds < 2 ? 0.1 : Double(centiseconds) / 100
        }
        let raw = frameDelay(props, kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
            ?? frameDelay(props, kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
            ?? 0.1
        return raw > 0 ? raw : 0.1
    }

    /// Nil when this format does not give a delay. The unclamped value wins, then the clamped one.
    private static func frameDelay(_ props: [CFString: Any], _ dictionary: CFString, _ unclamped: CFString, _ clamped: CFString) -> Double? {
        guard let bag = props[dictionary] as? [CFString: Any] else { return nil }
        return seconds(bag[unclamped]) ?? seconds(bag[clamped])
    }

    private static func seconds(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}
