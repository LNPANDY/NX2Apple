import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A stand-in app icon for a game whose package carries no control data (a Switch 2 game from a NUP or a dump folder, LNPANDY/NX2Apple#784):
/// the engine finds no icon in it and the Mac app's icon stays blank. The launcher makes a 256×256 JPEG, the size the engine's own icon has,
/// from the artwork it already cached for the game, and a build hands its path to the engine as `--fallback-icon`. The game's own icon
/// always wins, the iOS app and the shared shell never use it (so the shell's icon is not touched), and no artwork is fetched for it.
enum FallbackIcon {
    static let size = 256
    static let option = "--fallback-icon"

    /// A square crop around the middle of `image`, scaled to `size`, as JPEG data. nil for an image with no pixels.
    static func jpeg(from image: CGImage, size: Int = FallbackIcon.size) -> Data? {
        let side = min(image.width, image.height)
        guard side > 0,
              let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The stand-in for `titleID` written into `folder` from the banner already in `banners`, or nil without one. Re-made each time: it is cheap
    /// and follows a changed banner.
    static func file(titleID: String, banners: URL, folder: URL) -> URL? {
        guard let cached = ArtworkStore.cachedBanner(titleID, in: banners),
              let source = CGImageSourceCreateWithURL(cached as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let data = jpeg(from: image) else { return nil }
        let target = folder.appendingPathComponent("fallback-icon-\(titleID.uppercased()).jpg")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return target
        } catch { return nil }
    }

    /// The arguments a Mac app build adds for a game: `--fallback-icon` and the stand-in's path, or nothing.
    static func arguments(titleID: String, banners: URL, folder: URL) -> [String] {
        file(titleID: titleID, banners: banners, folder: folder).map { [option, $0.path] } ?? []
    }
}
