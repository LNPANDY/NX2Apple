import SwiftUI
import AppKit
import NXLauncher

/// Shared opacity timing for Library and console artwork and metadata.
enum LibraryHeroTransition {
    static func queue(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.28)
    }
    static func artwork(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.22)
    }
    static func blurredMetadata(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: CalmTransition(blur: 8, opacity: 0), identity: CalmTransition())
    }
    static func metadata(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.16)
    }
}

/// Manrope's embedded font metrics ignore SwiftUI leading adjustments.
struct ConsoleSheetTitle: NSViewRepresentable {
    let text: String
    let size: CGFloat

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 3
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = size * 1.12
        paragraph.maximumLineHeight = size * 1.12
        paragraph.lineBreakMode = .byWordWrapping
        let font = Typography.manropeFont(size: size, weight: .heavy).map { $0 as NSFont }
            ?? NSFont.systemFont(ofSize: size, weight: .heavy)
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 500
        let measured = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(measured?.height ?? size * 1.12))
    }
}
