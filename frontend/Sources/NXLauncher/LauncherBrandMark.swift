import SwiftUI
import CoreImage

package struct LauncherBrandMark: View {
    var onHero: Bool
    package init(onHero: Bool = false) { self.onHero = onHero }
    // Inline SVG keeps the mark available without a bundle resource lookup.
    package static let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="592" height="424" viewBox="216.21 288.35 591.58 424.39">
  <title>NX2Apple</title>
  <g transform="translate(0 -8)">
    <path fill="#FFF0D6" fill-rule="nonzero" d="M216.21 608.35L216.21 302.62L299.49 302.62L299.49 352.96L301.20 352.96Q313.04 326.58 336.42 311.46Q359.81 296.35 394.46 296.35Q444.80 296.35 472.32 326.79Q499.84 357.24 499.84 411.00L499.84 608.35L416.56 608.35L416.56 428.25Q416.56 398.31 402.52 381.84Q388.47 365.37 360.38 365.37Q341.84 365.37 328.15 373.85Q314.46 382.33 306.98 397.45Q299.49 412.56 299.49 432.67L299.49 608.35ZM511.75 608.35L607.58 456.06L512.47 302.62L606.30 302.62L661.20 406.01L662.91 406.01L717.24 302.62L807.79 302.62L712.25 453.92L807.07 608.35L716.52 608.35L658.49 502.40L656.78 502.40L599.31 608.35Z"/>
  </g>
  <path fill="#FFF0D6" fill-rule="nonzero" d="M612.57 696.58L612.57 696.58C612.57 687.66 605.33 680.43 596.41 680.43L427.59 680.43C418.67 680.43 411.43 687.66 411.43 696.58L411.43 696.58C411.43 705.51 418.67 712.74 427.59 712.74L596.41 712.74C605.33 712.74 612.57 705.51 612.57 696.58Z"/>
</svg>
"""
    package static let image = NSImage(data: Data(svg.utf8))
    // Cache the blurred alpha mask so the decorative backdrop also stays soft in AppKit bitmap rendering.
    package static let backdropImage: NSImage? = {
        guard let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let cg = bitmap.cgImage else { return nil }
        let source = CIImage(cgImage: cg)
        let blurred = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
        let bounds = source.extent.insetBy(dx: -72, dy: -72)
        guard let result = CIContext().createCGImage(blurred, from: bounds) else { return nil }
        return NSImage(cgImage: result, size: bounds.size)
    }()

    package var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
            }
        }
        .foregroundStyle(onHero ? Color.white : LauncherPalette.cream)
        .frame(width: 36, height: 26)
        .accessibilityLabel("NX2Apple")
        .allowsHitTesting(false)
    }
}
