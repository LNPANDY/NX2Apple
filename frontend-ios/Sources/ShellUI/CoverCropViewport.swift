import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure value-type viewport model for the interactive 16:9 cover cropper.
///
/// `scale` is in viewport points per source-image pixel. `offset` is the image center's
/// translation relative to the crop frame center in viewport points.
public struct CoverCropViewport: Equatable, Sendable {
    public static let aspectRatio: CGFloat = 16.0 / 9.0
    public static let maxZoomMultiplier: CGFloat = 5.0
    public static let maxOutputSize = CGSize(width: 1920, height: 1080)

    public var scale: CGFloat
    public var offset: CGSize

    public init(scale: CGFloat = 1, offset: CGSize = .zero) {
        self.scale = scale
        self.offset = offset
    }

    /// Initial centered aspect-fill viewport that completely covers `viewportSize`.
    public static func initial(imageSize: CGSize, viewportSize: CGSize) -> Self {
        Self(scale: minScale(imageSize: imageSize, viewportSize: viewportSize), offset: .zero)
    }

    /// Minimum scale at which the source image completely covers the 16:9 crop frame without empty bars.
    public static func minScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, viewportSize.width > 0, viewportSize.height > 0 else {
            return 1
        }
        return max(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
    }

    /// Maximum allowed zoom scale (`5x` of `minScale`).
    public static func maxScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        minScale(imageSize: imageSize, viewportSize: viewportSize) * maxZoomMultiplier
    }

    /// Maximum legal absolute center offset in points so the image edges never retreat inside the crop frame.
    public static func maxOffset(scale: CGFloat, imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, viewportSize.width > 0, viewportSize.height > 0 else {
            return .zero
        }
        let displayWidth = imageSize.width * scale
        let displayHeight = imageSize.height * scale
        return CGSize(
            width: max(0, (displayWidth - viewportSize.width) * 0.5),
            height: max(0, (displayHeight - viewportSize.height) * 0.5)
        )
    }

    /// Returns a copy with `scale` and `offset` clamped to valid bounds.
    public func clamped(imageSize: CGSize, viewportSize: CGSize) -> Self {
        let minS = Self.minScale(imageSize: imageSize, viewportSize: viewportSize)
        let maxS = Self.maxScale(imageSize: imageSize, viewportSize: viewportSize)
        let safeScale = scale.isFinite ? min(maxS, max(minS, scale)) : minS
        let bounds = Self.maxOffset(scale: safeScale, imageSize: imageSize, viewportSize: viewportSize)
        let safeX = offset.width.isFinite ? min(bounds.width, max(-bounds.width, offset.width)) : 0
        let safeY = offset.height.isFinite ? min(bounds.height, max(-bounds.height, offset.height)) : 0
        return Self(scale: safeScale, offset: CGSize(width: safeX, height: safeY))
    }

    /// Applies an incremental pinch magnification (anchored around the crop frame center) and drag translation.
    public func transformed(
        magnification: CGFloat,
        translation: CGSize,
        imageSize: CGSize,
        viewportSize: CGSize
    ) -> Self {
        let base = clamped(imageSize: imageSize, viewportSize: viewportSize)
        let minS = Self.minScale(imageSize: imageSize, viewportSize: viewportSize)
        let maxS = Self.maxScale(imageSize: imageSize, viewportSize: viewportSize)
        let factor = magnification.isFinite && magnification > 0 ? magnification : 1
        let targetScale = min(maxS, max(minS, base.scale * factor))
        let ratio = base.scale > 0 ? targetScale / base.scale : 1
        let rawOffset = CGSize(
            width: base.offset.width * ratio + (translation.width.isFinite ? translation.width : 0),
            height: base.offset.height * ratio + (translation.height.isFinite ? translation.height : 0)
        )
        return Self(scale: targetScale, offset: rawOffset).clamped(imageSize: imageSize, viewportSize: viewportSize)
    }

    /// Preserves the visible crop region when the on-screen crop frame resizes (e.g. device rotation).
    public func adapted(from oldViewportSize: CGSize, to newViewportSize: CGSize, imageSize: CGSize) -> Self {
        guard oldViewportSize.width > 0, newViewportSize.width > 0 else {
            return Self.initial(imageSize: imageSize, viewportSize: newViewportSize)
        }
        let ratio = newViewportSize.width / oldViewportSize.width
        return Self(
            scale: scale * ratio,
            offset: CGSize(width: offset.width * ratio, height: offset.height * ratio)
        ).clamped(imageSize: imageSize, viewportSize: newViewportSize)
    }

    /// Exact source-image crop rectangle in top-left-origin pixel coordinates (`[0, imageSize]`).
    public func cropRect(imageSize: CGSize, viewportSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewportSize.width > 0, viewportSize.height > 0 else {
            return CGRect(origin: .zero, size: imageSize)
        }
        let valid = clamped(imageSize: imageSize, viewportSize: viewportSize)
        let s = valid.scale
        let cropW = min(imageSize.width, max(1, viewportSize.width / s))
        let cropH = min(imageSize.height, max(1, viewportSize.height / s))
        let rawX = (imageSize.width - cropW) * 0.5 - valid.offset.width / s
        let rawY = (imageSize.height - cropH) * 0.5 - valid.offset.height / s
        let cropX = min(max(0, imageSize.width - cropW), max(0, rawX))
        let cropY = min(max(0, imageSize.height - cropH), max(0, rawY))
        return CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
    }
}

/// Decodes user-selected photos with EXIF orientation normalized upright and renders 16:9 cropped JPEGs.
public enum CoverImageProcessor {
    /// Decodes image bytes into an upright sRGB-compatible `CGImage`, applying any EXIF orientation tag.
    /// Large images are capped at `maxPixelDimension` on their longest side without upscaling smaller images.
    public static func decodeNormalizedImage(from data: Data, maxPixelDimension: Int = 4096) -> CGImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
            ?? (properties?[kCGImagePropertyOrientation] as? Int).map(UInt32.init)
            ?? CGImagePropertyOrientation.up.rawValue
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up

        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let maxSide = max(pixelWidth, pixelHeight)

        let decoded: CGImage?
        if maxPixelDimension > 0, maxSide > maxPixelDimension {
            // Downsample huge camera photos via ImageIO before allocating full bitmaps.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let decoded else { return nil }
        return normalizeOrientation(decoded, orientation: orientation)
    }

    /// Re-renders `image` into an upright `CGImage` according to its EXIF orientation.
    public static func normalizeOrientation(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        guard orientation != .up else { return image }
        let origW = CGFloat(image.width)
        let origH = CGFloat(image.height)
        guard origW > 0, origH > 0 else { return nil }

        let swapsAxes: Bool
        let transform: CGAffineTransform
        switch orientation {
        case .up:
            return image
        case .upMirrored:
            swapsAxes = false
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: origW, ty: 0)
        case .down:
            swapsAxes = false
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: origW, ty: origH)
        case .downMirrored:
            swapsAxes = false
            transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: origH)
        case .leftMirrored:
            swapsAxes = true
            transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: origH, ty: origW)
        case .right:
            swapsAxes = true
            transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: origW)
        case .rightMirrored:
            swapsAxes = true
            transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left:
            swapsAxes = true
            transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: origH, ty: 0)
        }

        let outW = Int(swapsAxes ? origH : origW)
        let outH = Int(swapsAxes ? origW : origH)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: outW,
                  height: outH,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.concatenate(transform)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: origW, height: origH))
        return ctx.makeImage()
    }

    /// Computes final pixel dimensions for a crop rect: downscales to fit `maxOutputSize` when larger,
    /// and preserves native cropped pixel dimensions when smaller (never upscaling).
    public static func outputSize(for cropRect: CGRect, maxOutputSize: CGSize = CoverCropViewport.maxOutputSize) -> CGSize {
        let srcW = max(1, cropRect.width)
        let srcH = max(1, cropRect.height)
        let maxW = max(1, maxOutputSize.width)
        let maxH = max(1, maxOutputSize.height)
        let downscale = min(1, min(maxW / srcW, maxH / srcH))
        let outW = max(1, min(Int(maxW.rounded()), Int((srcW * downscale).rounded())))
        let outH = max(1, min(Int(maxH.rounded()), Int((srcH * downscale).rounded())))
        return CGSize(width: outW, height: outH)
    }

    /// Renders the region described by `viewport` into an opaque sRGB 16:9 JPEG.
    public static func renderCroppedJPEG(
        from image: CGImage,
        viewport: CoverCropViewport,
        viewportSize: CGSize,
        maxOutputSize: CGSize = CoverCropViewport.maxOutputSize,
        quality: CGFloat = 0.9
    ) -> Data? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let cropRect = viewport.cropRect(imageSize: imageSize, viewportSize: viewportSize)
        return renderCroppedJPEG(from: image, cropRect: cropRect, maxOutputSize: maxOutputSize, quality: quality)
    }

    /// Renders `cropRect` (top-left-origin source pixels) into an opaque sRGB JPEG.
    public static func renderCroppedJPEG(
        from image: CGImage,
        cropRect: CGRect,
        maxOutputSize: CGSize = CoverCropViewport.maxOutputSize,
        quality: CGFloat = 0.9
    ) -> Data? {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        guard imgW > 0, imgH > 0, cropRect.width > 0, cropRect.height > 0 else { return nil }

        let target = outputSize(for: cropRect, maxOutputSize: maxOutputSize)
        let outW = Int(target.width)
        let outH = Int(target.height)
        guard outW > 0, outH > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: outW,
                  height: outH,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }

        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.interpolationQuality = .high

        let scaleX = CGFloat(outW) / cropRect.width
        let scaleY = CGFloat(outH) / cropRect.height
        let drawRect = CGRect(
            x: -cropRect.minX * scaleX,
            y: -(imgH - cropRect.maxY) * scaleY,
            width: imgW * scaleX,
            height: imgH * scaleY
        )
        ctx.draw(image, in: drawRect)

        guard let rendered = ctx.makeImage() else { return nil }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let clampedQuality = min(1, max(0.1, quality))
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: clampedQuality]
        CGImageDestinationAddImage(dest, rendered, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }
}
