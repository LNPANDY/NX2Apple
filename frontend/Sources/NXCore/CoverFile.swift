import Foundation
import ImageIO
import CoreGraphics

/// What Change artwork may point at, and what an install copies into the phone app.
/// A movie is copied as itself. ImageIO reads a still or a GIF (and an animated WebP or APNG) frame by frame.
package enum CoverFile {
    /// Extensions the shell library looks for, in the order it tries them. The install deletes every one of these before it writes the new banner.
    package static let shellExtensions = ["png", "jpg", "jpeg", "heic", "webp", "gif", "mp4", "mov", "m4v"]
    package static let movieExtensions: Set<String> = ["mp4", "mov", "m4v"]

    package static func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }
    package static func isMovie(_ path: String) -> Bool { movieExtensions.contains(ext(path)) }

    package struct Frame {
        package let image: CGImage
        package let seconds: Double
    }

    /// Empty when the path is a movie or ImageIO cannot read it.
    package static func frames(at path: String) -> [Frame] {
        guard !path.isEmpty, !isMovie(path),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return [] }
        var out: [Frame] = []
        for i in 0..<CGImageSourceGetCount(src) {
            guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            out.append(Frame(image: image, seconds: delay(src, i)))
        }
        return out
    }

    /// A GIF, an animated WebP or APNG, or a silent movie. A still returns false, including an empty path.
    /// JPEG, HEIC and TIFF are one picture, so they are not opened.
    package static func animates(_ path: String) -> Bool {
        if path.isEmpty { return false }
        if isMovie(path) { return true }
        if ["jpg", "jpeg", "heic", "tif", "tiff"].contains(ext(path)) { return false }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    /// GIF, WebP and APNG delays of 0 mean "as fast as you like". 0.1s is the usual stand-in, and the floor for a missing delay.
    private static func delay(_ src: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] else { return 0.1 }
        let raw = frameDelay(props, kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime)
            ?? frameDelay(props, kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
            ?? frameDelay(props, kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
            ?? 0.1
        return raw < 0.02 ? 0.1 : raw
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
