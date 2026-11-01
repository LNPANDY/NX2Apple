import AppKit

/// The Dock icon mirrors a running build like the App Store mirrors a download: the app icon with a
/// native gray progress bar along its bottom, so a build's progress is visible from wherever the
/// launcher was left. macOS has no public API for the App Store bar, so this is a plain
/// NSProgressIndicator on the Dock tile.
enum DockProgress {
    /// The text for a progress fraction (accessibility label); nil clears the tile. Pure, so tests run it.
    static func percentText(_ fraction: Double?) -> String? {
        guard let fraction, fraction.isFinite, fraction >= 0, fraction <= 1 else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// The tile's view: the app icon with a bar style progress indicator near its bottom edge.
    static func makeTileView(fraction: Double, icon: NSImage, size: CGFloat = 128) -> NSView {
        let tile = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        let iconView = NSImageView(frame: tile.bounds)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        tile.addSubview(iconView)

        let inset = size * 0.18
        let bar = NSProgressIndicator(frame: NSRect(x: inset, y: size * 0.17, width: size - 2 * inset, height: 14))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = min(max(fraction, 0), 1)
        bar.controlSize = .regular
        bar.appearance = NSAppearance(named: .aqua)
        bar.setAccessibilityLabel(percentText(fraction))
        // The App Store bar is gray, not the accent color, and NSProgressIndicator has no tint on
        // current macOS. So the native bar is drawn to a bitmap, desaturated, and shown as an image.
        let barImage = grayImage(of: bar)
        let barView = NSImageView(frame: bar.frame)
        barView.image = barImage
        barView.imageScaling = .scaleAxesIndependently
        tile.addSubview(barView)
        return tile
    }

    /// The view drawn to an image with its colors turned to gray.
    static func grayImage(of view: NSView) -> NSImage {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return NSImage() }
        view.cacheDisplay(in: view.bounds, to: rep)
        let color = NSImage(size: view.bounds.size)
        color.addRepresentation(rep)
        guard let cg = rep.cgImage,
              let filter = CIFilter(name: "CIColorControls", parameters: [
                  kCIInputImageKey: CIImage(cgImage: cg), kCIInputSaturationKey: 0.0]),
              let out = filter.outputImage,
              let gray = CIContext().createCGImage(out, from: out.extent) else { return color }
        return NSImage(cgImage: gray, size: view.bounds.size)
    }

    /// Reflects the running build on the Dock tile; nil restores the plain icon.
    static func update(_ fraction: Double?) {
        let dock = NSApplication.shared.dockTile
        guard let fraction, percentText(fraction) != nil else {
            dock.contentView = nil
            dock.display()
            return
        }
        dock.contentView = makeTileView(fraction: fraction, icon: NSApplication.shared.applicationIconImage,
                                        size: dock.size.width)
        dock.display()
    }
}
