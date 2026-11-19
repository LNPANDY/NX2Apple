import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ShellUI

@Suite struct CoverCropTests {
    private let viewportSize = CGSize(width: 320, height: 180)

    // MARK: - CoverCropViewport geometry and clamping

    @Test func minScaleCoversViewportForAllAspectRatios() {
        let cases: [(name: String, size: CGSize, expectedMin: CGFloat)] = [
            ("16:9 landscape", CGSize(width: 1920, height: 1080), 320.0 / 1920.0),
            ("9:16 portrait", CGSize(width: 1080, height: 1920), 320.0 / 1080.0),
            ("1:1 square", CGSize(width: 1000, height: 1000), 320.0 / 1000.0),
            ("32:9 ultrawide", CGSize(width: 3840, height: 1080), 180.0 / 1080.0),
        ]
        for item in cases {
            let minS = CoverCropViewport.minScale(imageSize: item.size, viewportSize: viewportSize)
            #expect(abs(minS - item.expectedMin) < 1e-6, "\(item.name)")
            #expect(item.size.width * minS + 1e-4 >= viewportSize.width, "\(item.name) covers width")
            #expect(item.size.height * minS + 1e-4 >= viewportSize.height, "\(item.name) covers height")
            let maxS = CoverCropViewport.maxScale(imageSize: item.size, viewportSize: viewportSize)
            #expect(abs(maxS - minS * CoverCropViewport.maxZoomMultiplier) < 1e-6)
        }
    }

    @Test func offsetAndScaleAreStrictlyClamped() {
        // 1000x1000 square in 320x180 viewport -> minScale = 0.32 -> display 320x320 -> maxOffset = (0, 70)
        let square = CGSize(width: 1000, height: 1000)
        let tooSmall = CoverCropViewport(scale: 0.01, offset: CGSize(width: 500, height: -999))
            .clamped(imageSize: square, viewportSize: viewportSize)
        #expect(abs(tooSmall.scale - 0.32) < 1e-6)
        #expect(abs(tooSmall.offset.width) < 1e-6)
        #expect(abs(tooSmall.offset.height - (-70)) < 1e-6)

        // Over-zoomed and non-finite inputs are clamped safely.
        let tooLarge = CoverCropViewport(scale: 999, offset: CGSize(width: CGFloat.infinity, height: CGFloat.nan))
            .clamped(imageSize: square, viewportSize: viewportSize)
        #expect(abs(tooLarge.scale - 0.32 * 5.0) < 1e-6)
        #expect(abs(tooLarge.offset.width) < 1e-6)
        #expect(abs(tooLarge.offset.height) < 1e-6)
    }

    @Test func cropRectMapsPortraitAndUltrawideExtremesPrecisely() {
        // Portrait 1080x1920 in 320x180 -> minScale = 320/1080 -> visible crop height = 180 / (320/1080) = 607.5 px.
        let portrait = CGSize(width: 1080, height: 1920)
        let centerRect = CoverCropViewport.initial(imageSize: portrait, viewportSize: viewportSize)
            .cropRect(imageSize: portrait, viewportSize: viewportSize)
        #expect(abs(centerRect.minX) < 1e-3)
        #expect(abs(centerRect.width - 1080) < 1e-3)
        #expect(abs(centerRect.height - 607.5) < 1e-3)
        #expect(abs(centerRect.minY - (1920 - 607.5) * 0.5) < 1e-3)

        // Dragging finger DOWN (+offset.height) reveals the TOP of the image (cropY == 0).
        let topRect = CoverCropViewport(scale: CoverCropViewport.minScale(imageSize: portrait, viewportSize: viewportSize),
                                        offset: CGSize(width: 0, height: 10_000))
            .cropRect(imageSize: portrait, viewportSize: viewportSize)
        #expect(abs(topRect.minY) < 1e-3)
        #expect(abs(topRect.height - 607.5) < 1e-3)

        // Dragging finger UP (-offset.height) reveals the BOTTOM of the image (maxY == 1920).
        let bottomRect = CoverCropViewport(scale: CoverCropViewport.minScale(imageSize: portrait, viewportSize: viewportSize),
                                           offset: CGSize(width: 0, height: -10_000))
            .cropRect(imageSize: portrait, viewportSize: viewportSize)
        #expect(abs(bottomRect.maxY - 1920) < 1e-3)

        // Ultrawide 3840x1080 in 320x180 -> minScale = 180/1080 = 1/6 -> cropWidth = 1920.
        let ultrawide = CGSize(width: 3840, height: 1080)
        let leftRect = CoverCropViewport(scale: CoverCropViewport.minScale(imageSize: ultrawide, viewportSize: viewportSize),
                                         offset: CGSize(width: 10_000, height: 0))
            .cropRect(imageSize: ultrawide, viewportSize: viewportSize)
        #expect(abs(leftRect.minX) < 1e-3)
        #expect(abs(leftRect.width - 1920) < 1e-3)
        #expect(abs(leftRect.height - 1080) < 1e-3)

        let rightRect = CoverCropViewport(scale: CoverCropViewport.minScale(imageSize: ultrawide, viewportSize: viewportSize),
                                          offset: CGSize(width: -10_000, height: 0))
            .cropRect(imageSize: ultrawide, viewportSize: viewportSize)
        #expect(abs(rightRect.maxX - 3840) < 1e-3)
        #expect(abs(rightRect.width - 1920) < 1e-3)
    }

    @Test func adaptingToResizedViewportPreservesSourceCropRect() {
        let imageSize = CGSize(width: 1600, height: 1200)
        let small = CGSize(width: 320, height: 180)
        let large = CGSize(width: 640, height: 360)
        let initial = CoverCropViewport.initial(imageSize: imageSize, viewportSize: small)
            .transformed(magnification: 2.0, translation: CGSize(width: 40, height: -30), imageSize: imageSize, viewportSize: small)
        let adapted = initial.adapted(from: small, to: large, imageSize: imageSize)
        let rectBefore = initial.cropRect(imageSize: imageSize, viewportSize: small)
        let rectAfter = adapted.cropRect(imageSize: imageSize, viewportSize: large)
        #expect(abs(rectBefore.minX - rectAfter.minX) < 1e-3)
        #expect(abs(rectBefore.minY - rectAfter.minY) < 1e-3)
        #expect(abs(rectBefore.width - rectAfter.width) < 1e-3)
        #expect(abs(rectBefore.height - rectAfter.height) < 1e-3)
    }

    // MARK: - EXIF orientation normalization & JPEG rendering

    @Test func decodeNormalizedImageMatchesImageIOForAllEightExifOrientations() throws {
        // 80x40 asymmetric quadrant bitmap: TL=Red, TR=Green, BL=Blue, BR=Yellow.
        let base = try makeQuadrantImage(width: 80, height: 40)
        let orientations: [CGImagePropertyOrientation] = [
            .up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left
        ]

        for orientation in orientations {
            let encoded = try encodeJPEG(base, orientation: orientation)
            let normalized = try #require(CoverImageProcessor.decodeNormalizedImage(from: encoded), "orientation \(orientation.rawValue)")

            // Compare directly against Apple ImageIO's authoritative EXIF transform.
            let src = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
            let reference = try #require(CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 200
            ] as CFDictionary))

            #expect(normalized.width == reference.width, "width mismatch for orientation \(orientation.rawValue)")
            #expect(normalized.height == reference.height, "height mismatch for orientation \(orientation.rawValue)")

            let w = normalized.width
            let h = normalized.height
            let probes = [(w / 4, h / 4), (3 * w / 4, h / 4), (w / 4, 3 * h / 4), (3 * w / 4, 3 * h / 4)]
            for (px, py) in probes {
                let got = try sampleRGB(normalized, x: px, y: py)
                let want = try sampleRGB(reference, x: px, y: py)
                #expect(abs(Int(got.r) - Int(want.r)) <= 20, "R mismatch for orientation \(orientation.rawValue) at (\(px),\(py)): \(got) vs \(want)")
                #expect(abs(Int(got.g) - Int(want.g)) <= 20, "G mismatch for orientation \(orientation.rawValue) at (\(px),\(py)): \(got) vs \(want)")
                #expect(abs(Int(got.b) - Int(want.b)) <= 20, "B mismatch for orientation \(orientation.rawValue) at (\(px),\(py)): \(got) vs \(want)")
            }
        }
    }

    @Test func renderCroppedJPEGCapsAt1080pAndNeverUpscalesSmallCrops() throws {
        // Large 3840x2160 image -> capped at 1920x1080.
        let large = try makeQuadrantImage(width: 3840, height: 2160)
        let largeData = try #require(CoverImageProcessor.renderCroppedJPEG(
            from: large,
            viewport: CoverCropViewport.initial(imageSize: CGSize(width: 3840, height: 2160), viewportSize: viewportSize),
            viewportSize: viewportSize
        ))
        let largeOut = try #require(Artwork(id: "large", data: largeData))
        #expect(largeOut.image.width == 1920)
        #expect(largeOut.image.height == 1080)

        // Small 800x450 image -> stays native 800x450 without upscaling.
        let small = try makeQuadrantImage(width: 800, height: 450)
        let smallData = try #require(CoverImageProcessor.renderCroppedJPEG(
            from: small,
            viewport: CoverCropViewport.initial(imageSize: CGSize(width: 800, height: 450), viewportSize: viewportSize),
            viewportSize: viewportSize
        ))
        let smallOut = try #require(Artwork(id: "small", data: smallData))
        #expect(smallOut.image.width == 800)
        #expect(smallOut.image.height == 450)

        // Zooming 2x and dragging down-right crops the top-left RED quadrant accurately.
        let quad = try makeQuadrantImage(width: 640, height: 360)
        let zoomedTopLeft = CoverCropViewport(scale: 1.0, offset: CGSize(width: 160, height: 90))
        let redData = try #require(CoverImageProcessor.renderCroppedJPEG(
            from: quad,
            viewport: zoomedTopLeft,
            viewportSize: viewportSize
        ))
        let redOut = try #require(Artwork(id: "red", data: redData))
        #expect(redOut.image.width == 320)
        #expect(redOut.image.height == 180)
        let pixel = try sampleRGB(redOut.image, x: 160, y: 90)
        #expect(pixel.r > 200 && pixel.g < 40 && pixel.b < 40, "expected red quadrant, got \(pixel)")
    }

    // MARK: - FocusLayer & system-echo protection

    @Test @MainActor func coverCropFocusLayerAndGuardedActionsIsolateEchoes() {
        #expect(FocusLayer.coverCrop.prefix == "crp.")
        #expect(FocusLayer.isLive("crp.done", under: .coverCrop))
        #expect(!FocusLayer.isLive("set.cover", under: .coverCrop))
        #expect(FocusLayer.isLive("set.cover", under: .settings))
        #expect(FocusLayer.isLive("set.cover.reset", under: .settings))
        #expect(!LibraryView.optionsOpensShellSettings(under: .coverCrop))

        var savedCount = 0
        var resetCount = 0
        let actions = ShellActions(
            onSaveCustomCover: { _, _ in savedCount += 1 },
            onResetCustomCover: { _ in resetCount += 1 }
        )
        #expect(actions.supportsCustomCover)
        let view = LibraryView(games: [], actions: actions)
        let gate = InputGate(clock: { 10 }, echoes: true)
        gate.controller(.activate)
        #expect(gate.isSystemEcho)
        // Guarded closures in LibraryView should invoke callbacks when not echoing.
        view.guardedActions.onSaveCustomCover?("0100000000010000", Data([1, 2, 3]))
        view.guardedActions.onResetCustomCover?("0100000000010000")
        #expect(savedCount == 1)
        #expect(resetCount == 1)
    }

    // MARK: - Helpers

    private func makeQuadrantImage(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let hw = width / 2
        let hh = height / 2
        // CoreGraphics origin is bottom-left.
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1) // Bottom-left: Blue
        ctx.fill(CGRect(x: 0, y: 0, width: hw, height: hh))
        ctx.setFillColor(red: 1, green: 1, blue: 0, alpha: 1) // Bottom-right: Yellow
        ctx.fill(CGRect(x: hw, y: 0, width: width - hw, height: hh))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1) // Top-left: Red
        ctx.fill(CGRect(x: 0, y: hh, width: hw, height: height - hh))
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1) // Top-right: Green
        ctx.fill(CGRect(x: hw, y: hh, width: width - hw, height: height - hh))
        return try #require(ctx.makeImage())
    }

    private func encodeJPEG(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> Data {
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 1.0
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// Samples pixel at top-left-origin `(x, y)` in sRGB 8-bit.
    private func sampleRGB(_ image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let w = image.width
        let h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        #expect(ok)
        let offset = (y * w + x) * 4
        return (buf[offset], buf[offset + 1], buf[offset + 2])
    }
}
