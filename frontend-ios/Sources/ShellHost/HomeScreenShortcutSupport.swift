import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import Photos
#endif

/// Saves rendered PNG bytes to Photos entirely from a `nonisolated` context so Swift 6 never infers `@MainActor`
/// isolation onto PhotoKit's background `changeBlock` or `completionHandler` queues (`_dispatch_assert_queue_fail`).
public enum PhotoLibraryImageSaver {
    public typealias PerformChangesHandler = @Sendable (
        _ changeBlock: @escaping @Sendable () -> Void,
        _ completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    ) -> Void

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false

        nonisolated init() {}

        nonisolated func tryEnter() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !entered else { return false }
            entered = true
            return true
        }
    }

    public nonisolated static func savePNGData(
        _ pngData: Data,
        requestAccess: @Sendable () async -> Bool,
        performChanges: PerformChangesHandler,
        writeAsset: @escaping @Sendable (Data) -> Void
    ) async -> Bool {
        guard !pngData.isEmpty else { return false }
        guard await requestAccess() else { return false }
        let payload = pngData
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = OnceGate()
            let changeBlock: @Sendable () -> Void = {
                writeAsset(payload)
            }
            let completion: @Sendable (Bool, (any Error)?) -> Void = { ok, error in
                if gate.tryEnter() {
                    continuation.resume(returning: ok && error == nil)
                }
            }
            performChanges(changeBlock, completion)
        }
    }

    #if os(iOS)
    private nonisolated static func requestPhotoAddAuthorization() async -> Bool {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            let gate = OnceGate()
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if gate.tryEnter() {
                    continuation.resume(returning: status)
                }
            }
        }
        return status == .authorized || status == .limited
    }

    private nonisolated static func performSystemPhotoChanges(
        _ changeBlock: @escaping @Sendable () -> Void,
        completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    ) {
        PHPhotoLibrary.shared().performChanges(changeBlock, completionHandler: completionHandler)
    }

    private nonisolated static func createPhotoAsset(from pngData: Data) {
        let request = PHAssetCreationRequest.forAsset()
        request.addResource(with: .photo, data: pngData, options: nil)
    }

    public nonisolated static func saveToSystemPhotoLibrary(_ pngData: Data) async -> Bool {
        await savePNGData(
            pngData,
            requestAccess: requestPhotoAddAuthorization,
            performChanges: performSystemPhotoChanges,
            writeAsset: createPhotoAsset
        )
    }
    #endif
}

/// Metadata for one installed game exposed to Apple Shortcuts (`AppIntents`) and Home Screen icon generation.
public struct ShortcutGameItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var titleID: String
    public var title: String
    public var iconPNG: Data?

    public init(id: String, titleID: String, title: String, iconPNG: Data? = nil) {
        self.id = id
        self.titleID = titleID
        self.title = title
        self.iconPNG = iconPNG
    }
}

/// Pure helpers for rendering opaque square Home Screen icons and listing installed games for `AppIntents`.
public enum HomeScreenShortcutSupport {
    public static let createShortcutURL = URL(string: "shortcuts://create-shortcut")!
    public static let shortcutsAppURL = URL(string: "shortcuts://")!

    /// Enumerates installed, non-deleted games across bundled `Frameworks/` and hot-pushed `Documents/Frameworks/`.
    public static func availableGames(
        gamesRoot: URL,
        hotFrameworksRoot: URL? = nil,
        appDataRoot: URL? = nil,
        defaults: (String) -> UserDefaults = GameDefaults.suite(for:),
        includeThumbnails: Bool = true
    ) -> [ShortcutGameItem] {
        let entries = GameCatalogue.scan(root: gamesRoot, hotRoot: hotFrameworksRoot, gameDataRoot: appDataRoot)
        return entries
            .filter { entry in
                guard entry.manifest != nil || entry.readableName != nil else { return false }
                return !defaults(entry.id).bool(forKey: GameDeletion.deletedKey)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { entry in
                ShortcutGameItem(
                    id: entry.shortcutFrameworkIdentifier,
                    titleID: entry.id,
                    title: entry.title,
                    iconPNG: includeThumbnails ? renderSquareIconPNG(for: entry, size: 128) : nil
                )
            }
    }

    /// Renders an opaque `size x size` sRGB PNG for the Home Screen (no alpha channel, avoiding iOS black-fill artifacts).
    public static func renderSquareIconPNG(for entry: CatalogueEntry, size: Int = 512) -> Data? {
        renderSquareIconPNG(
            iconURL: entry.iconURL,
            bannerURL: entry.bannerURL,
            title: entry.title,
            seed: entry.id,
            size: size
        )
    }

    public static func renderSquareIconPNG(
        iconURL: URL? = nil,
        bannerURL: URL? = nil,
        title: String,
        seed: String,
        size: Int = 512
    ) -> Data? {
        let side = max(32, size)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }

        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ctx.setFillColor(red: 0.055, green: 0.055, blue: 0.06, alpha: 1)
        ctx.fill(bounds)

        if let sourceImage = loadCGImage(from: iconURL) ?? loadCGImage(from: bannerURL) {
            ctx.interpolationQuality = .high
            let srcW = CGFloat(max(1, sourceImage.width))
            let srcH = CGFloat(max(1, sourceImage.height))
            let scale = max(CGFloat(side) / srcW, CGFloat(side) / srcH)
            let drawW = srcW * scale
            let drawH = srcH * scale
            let rect = CGRect(
                x: (CGFloat(side) - drawW) * 0.5,
                y: (CGFloat(side) - drawH) * 0.5,
                width: drawW,
                height: drawH
            )
            ctx.draw(sourceImage, in: rect)
        } else {
            drawPlaceholder(in: ctx, side: CGFloat(side), title: title, seed: seed)
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func loadCGImage(from url: URL?) -> CGImage? {
        guard let url,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func drawPlaceholder(in ctx: CGContext, side: CGFloat, title: String, seed: String) {
        let hash = seed.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) }
        let hue = CGFloat(hash % 360) / 360.0
        let topColor = hsbColor(h: hue, s: 0.42, b: 0.38)
        let bottomColor = hsbColor(h: hue, s: 0.55, b: 0.14)
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorsSpace: space, colors: [bottomColor, topColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: side, y: side),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        let glow = hsbColor(h: hue, s: 0.30, b: 0.62, a: 0.28)
        ctx.setFillColor(glow)
        let glowSize = side * 1.05
        ctx.fillEllipse(in: CGRect(x: side * 0.28, y: side * 0.25, width: glowSize, height: glowSize))

        let initials = placeholderInitials(from: title)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, side * 0.28, nil)
        let cream = CGColor(srgbRed: 1.0, green: 0.94, blue: 0.84, alpha: 0.94)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cream
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: initials, attributes: attrs))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let x = max(side * 0.1, (side - width) * 0.5)
        let y = (side - (ascent - descent)) * 0.5
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    private static func placeholderInitials(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "NX" }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "-" })
        if words.count >= 2, let first = words[0].first, let second = words[1].first {
            return String([first, second]).uppercased()
        }
        return String(trimmed.prefix(2)).uppercased()
    }

    private static func hsbColor(h: CGFloat, s: CGFloat, b: CGFloat, a: CGFloat = 1.0) -> CGColor {
        let c = b * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = b - c
        let (r1, g1, b1): (CGFloat, CGFloat, CGFloat)
        switch Int(h * 6) % 6 {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return CGColor(srgbRed: r1 + m, green: g1 + m, blue: b1 + m, alpha: a)
    }
}

/// Renders high-contrast 16:9 dark step cards as `CGImage` and IOSurface-backed `CVPixelBuffer` frames for PiP.
public enum HomeScreenGuideCardRenderer {
    public static let defaultSize = CGSize(width: 960, height: 540)
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

    public static func renderPixelBuffer(
        stepper: HomeScreenGuideStepper,
        iconPNG: Data? = nil,
        hintText: String = "",
        size: CGSize = defaultSize
    ) -> CVPixelBuffer? {
        let width = max(64, Int(size.width.rounded()))
        let height = max(64, Int(size.height.rounded()))
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: base,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                  space: space,
                  bitmapInfo: bitmapInfo
              ) else {
            return nil
        }
        drawCard(in: ctx, size: CGSize(width: width, height: height), stepper: stepper, iconPNG: iconPNG, hintText: hintText)
        return buffer
    }

    public static func renderCGImage(
        stepper: HomeScreenGuideStepper,
        iconPNG: Data? = nil,
        hintText: String = "",
        size: CGSize = defaultSize
    ) -> CGImage? {
        let width = max(64, Int(size.width.rounded()))
        let height = max(64, Int(size.height.rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: bitmapInfo
              ) else {
            return nil
        }
        drawCard(in: ctx, size: CGSize(width: width, height: height), stepper: stepper, iconPNG: iconPNG, hintText: hintText)
        return ctx.makeImage()
    }

    private static func drawCard(
        in ctx: CGContext,
        size: CGSize,
        stepper: HomeScreenGuideStepper,
        iconPNG: Data?,
        hintText: String
    ) {
        let w = size.width
        let h = size.height
        let margin: CGFloat = 44
        let headerY = h - 98
        let iconSide: CGFloat = 56
        let cream = CGColor(srgbRed: 0.96, green: 0.91, blue: 0.80, alpha: 1)
        let darkInk = CGColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)

        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let grad = CGGradient(
               colorsSpace: space,
               colors: [
                   CGColor(srgbRed: 0.055, green: 0.065, blue: 0.09, alpha: 1),
                   CGColor(srgbRed: 0.105, green: 0.12, blue: 0.165, alpha: 1),
               ] as CFArray,
               locations: [0, 1]
           ) {
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        }
        ctx.addPath(CGPath(roundedRect: CGRect(x: 10, y: 10, width: w - 20, height: h - 20), cornerWidth: 26, cornerHeight: 26, transform: nil))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
        ctx.setLineWidth(2)
        ctx.strokePath()

        let iconRect = CGRect(x: margin, y: headerY, width: iconSide, height: iconSide)
        drawIcon(in: ctx, rect: iconRect, iconPNG: iconPNG, title: stepper.gameTitle)

        let badgeLine = makeLine(stepper.progressText, font: systemFont(size: 25, bold: true), color: darkInk)
        let badgeW = max(92, CGFloat(CTLineGetTypographicBounds(badgeLine, nil, nil, nil)) + 34)
        let badgeH: CGFloat = 42
        let badgeRect = CGRect(x: w - margin - badgeW, y: headerY + (iconSide - badgeH) * 0.5, width: badgeW, height: badgeH)
        ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: badgeH * 0.5, cornerHeight: badgeH * 0.5, transform: nil))
        ctx.setFillColor(cream)
        ctx.fillPath()
        drawCenteredLine(badgeLine, in: badgeRect, ctx: ctx)

        let titleX = iconRect.maxX + 18
        let titleMaxW = max(40, badgeRect.minX - titleX - 18)
        let titleFont = systemFont(size: 26, bold: true)
        let titleColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.80)
        let rawTitle = makeLine(stepper.gameTitle, font: titleFont, color: titleColor)
        let titleLine = CTLineCreateTruncatedLine(rawTitle, Double(titleMaxW), .end, makeLine("…", font: titleFont, color: titleColor)) ?? rawTitle
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(titleLine, &ascent, &descent, nil)
        ctx.textPosition = CGPoint(x: titleX, y: headerY + (iconSide - (ascent - descent)) * 0.5)
        CTLineDraw(titleLine, ctx)

        let barY = headerY - 24
        let segments = max(1, stepper.totalSteps)
        let gap: CGFloat = 8
        let segW = (w - margin * 2 - gap * CGFloat(segments - 1)) / CGFloat(segments)
        for idx in 0..<segments {
            let segRect = CGRect(x: margin + CGFloat(idx) * (segW + gap), y: barY, width: segW, height: 6)
            ctx.addPath(CGPath(roundedRect: segRect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.setFillColor(idx <= stepper.currentIndex ? cream : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
            ctx.fillPath()
        }

        let bodyRect = CGRect(x: margin + 4, y: 96, width: w - (margin + 4) * 2, height: barY - 116)
        drawWrappedStep(stepper.currentStepText, in: bodyRect, ctx: ctx)

        if !hintText.isEmpty {
            let hintLine = makeLine(hintText, font: systemFont(size: 22, bold: false), color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55))
            drawCenteredLine(hintLine, in: CGRect(x: margin, y: 30, width: w - margin * 2, height: 42), ctx: ctx)
        }
    }

    private static func drawIcon(in ctx: CGContext, rect: CGRect, iconPNG: Data?, title: String) {
        ctx.saveGState()
        let clip = CGPath(roundedRect: rect, cornerWidth: 13, cornerHeight: 13, transform: nil)
        ctx.addPath(clip)
        ctx.clip()
        if let iconPNG,
           let src = CGImageSourceCreateWithData(iconPNG as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: rect)
        } else {
            ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.21, blue: 0.28, alpha: 1))
            ctx.fill(rect)
            let initials = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)).uppercased()
            let line = makeLine(initials.isEmpty ? "NX" : initials, font: systemFont(size: 22, bold: true),
                                color: CGColor(srgbRed: 0.96, green: 0.91, blue: 0.80, alpha: 0.95))
            drawCenteredLine(line, in: rect, ctx: ctx)
        }
        ctx.restoreGState()
        ctx.addPath(clip)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.setLineWidth(1.5)
        ctx.strokePath()
    }

    private static func drawWrappedStep(_ text: String, in rect: CGRect, ctx: CGContext) {
        guard !text.isEmpty else { return }
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.97)
        let para = makeParagraphStyle(lineSpacing: 10, alignment: .left)
        var chosen: CTFramesetter?
        var height = rect.height
        for fontSize: CGFloat in [44, 38, 32] {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): systemFont(size: fontSize, bold: true),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
            ]
            let fs = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(
                fs, CFRange(location: 0, length: 0), nil, CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil
            )
            chosen = fs
            height = min(rect.height, ceil(fit.height) + 4)
            if fit.height <= rect.height - 8 { break }
        }
        guard let fs = chosen else { return }
        let frameRect = CGRect(x: rect.minX, y: rect.minY + (rect.height - height) * 0.5, width: rect.width, height: height)
        CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), nil), ctx)
    }

    private static func makeParagraphStyle(lineSpacing: CGFloat, alignment: CTTextAlignment) -> CTParagraphStyle {
        var spacing = lineSpacing
        var align = alignment
        return withUnsafePointer(to: &spacing) { spacingPtr in
            withUnsafePointer(to: &align) { alignPtr in
                let settings = [
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: spacingPtr),
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignPtr),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }

    private static func systemFont(size: CGFloat, bold: Bool) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
        return bold ? (CTFontCreateCopyWithSymbolicTraits(base, size, nil, .boldTrait, .boldTrait) ?? base) : base
    }

    private static func makeLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
    }

    private static func drawCenteredLine(_ line: CTLine, in rect: CGRect, ctx: CGContext) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        ctx.textPosition = CGPoint(x: rect.minX + (rect.width - width) * 0.5, y: rect.minY + (rect.height - (ascent - descent)) * 0.5)
        CTLineDraw(line, ctx)
    }
}
