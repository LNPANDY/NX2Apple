import SwiftUI
import NXCore
import NXModel

/// Shared artwork status face, independent of the screen's localization owner.
package struct ArtworkStatusChip: View {
    package static let strokeWidth: CGFloat = 1
    package static let neutralColor = Color.white.opacity(0.9)
    let title: String
    var symbol: String?
    let color: Color
    var fontSize: CGFloat = 11
    var showsIndicator = true
    var textColor: Color?
    package init(title: String, symbol: String? = nil, color: Color, fontSize: CGFloat = 11, showsIndicator: Bool = true, textColor: Color? = nil) {
        self.title = title; self.symbol = symbol; self.color = color; self.fontSize = fontSize; self.showsIndicator = showsIndicator; self.textColor = textColor
    }
    package var body: some View {
        HStack(spacing: 6 * fontSize / 11) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            else if showsIndicator { Circle().fill(color).frame(width: 7 * fontSize / 11, height: 7 * fontSize / 11).accessibilityHidden(true) }
            Text(title).lineLimit(1).foregroundStyle(textColor ?? color)
        }
        .font(.manrope(fontSize, .semibold)).foregroundStyle(color)
        .padding(.horizontal, 8 * fontSize / 11).padding(.vertical, 4 * fontSize / 11)
        .background(.black, in: Capsule())
        .overlay(Capsule().strokeBorder(color, lineWidth: Self.strokeWidth))
        .accessibilityElement(children: .combine)
    }
}


/// Shared proportional outcome marker attached after the artwork's clipping shape.
package struct ArtworkOutcomeBadge: View {
    package enum Outcome { case success, warning, failure }
    @Environment(\.colorScheme) private var colorScheme
    let outcome: Outcome
    let artworkSize: CGFloat
    package init(_ outcome: Outcome, artworkSize: CGFloat) {
        self.outcome = outcome; self.artworkSize = artworkSize
    }
    private var color: Color {
        switch outcome {
        case .success: return LauncherPalette.ready
        case .warning: return LauncherPalette.building
        case .failure: return LauncherPalette.danger
        }
    }
    private var symbol: String {
        switch outcome {
        case .success: return "checkmark"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark"
        }
    }
    package var body: some View {
        ZStack {
            Circle().fill(.black)
            Circle().fill(color).padding(artworkSize * 0.055)
            Image(systemName: symbol).font(.system(size: artworkSize * 0.19, weight: .bold)).foregroundStyle(outcome != .failure && colorScheme == .dark ? .black : .white)
        }.frame(width: artworkSize * 0.44, height: artworkSize * 0.44)
            .offset(x: artworkSize * 0.06, y: artworkSize * 0.06)
            .accessibilityHidden(true)
    }
}


/// Build surfaces show each requested platform separately, without changing Library status chips.
package struct BuildPlatformChip: View {
    let targets: [String]
    var fontSize: CGFloat = 11
    @EnvironmentObject private var loc: Localizer
    package init(targets: [String], fontSize: CGFloat = 11) { self.targets = targets; self.fontSize = fontSize }
    package var body: some View {
        HStack(spacing: 6) {
            ForEach([BuildTarget.mac, BuildTarget.ios].filter { target in targets.map(BuildTarget.normalized).contains(target) }, id: \.self) { target in
                ArtworkStatusChip(title: loc.t(target == BuildTarget.mac ? "library.section.mac" : "build.ios"),
                    symbol: target == BuildTarget.mac ? "desktopcomputer" : "iphone", color: ArtworkStatusChip.neutralColor,
                    fontSize: fontSize, showsIndicator: false)
            }
        }
    }
}
