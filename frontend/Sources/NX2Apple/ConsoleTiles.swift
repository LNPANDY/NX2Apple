import SwiftUI
import NXCore
import NXLauncher

/// Reusable 1.8:1 presentation; nil artwork uses the same quiet surface as the desktop library.
/// A cover drawn from the title alone, in the launcher's palette: a dark gradient tinted by one of its accents, and the name.
/// Nothing is loaded or bundled. The same title always gets the same colors.
enum ConsolePlaceholder {
    static func colors(for title: String) -> [Color] {
        let accents = [LauncherPalette.cream, LauncherPalette.ready, LauncherPalette.building, LauncherPalette.unbuilt]
        let seed = title.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        let accent = accents[abs(seed) % accents.count]
        return [accent.opacity(0.42), LauncherPalette.surface, LauncherPalette.background]
    }
}

struct ConsoleArtwork: View {
    let image: NSImage?
    var title = ""
    var focus = UnitPoint.center
    var body: some View {
        GeometryReader { geometry in
            if let image { ArtworkFill(image: image, focus: focus).frame(width: geometry.size.width, height: geometry.size.height) }
            else {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: ConsolePlaceholder.colors(for: title), startPoint: .topLeading, endPoint: .bottomTrailing)
                    if title.isEmpty { Image(systemName: "gamecontroller").font(.system(size: 50)).foregroundStyle(LauncherPalette.secondaryText) }
                    else {
                        Text(title).font(.manrope(max(14, geometry.size.width / 11), .bold)).foregroundStyle(LauncherPalette.cream.opacity(0.9))
                            .lineLimit(3).minimumScaleFactor(0.6).padding(geometry.size.width / 18)
                    }
                }
            }
        }
    }
}

/// The width each button of the Home button hint was drawn at, by its pad id: ConsoleTests checks that it is the same in every language.
struct ConsoleButtonWidths: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { _, new in new } }
    static func reader(_ id: String) -> some View { GeometryReader { g in Color.clear.preference(key: ConsoleButtonWidths.self, value: [id: g.size.width]) } }
}

struct ConsoleGameTile: View {
    let game: ConsoleGame
    let selected: Bool
    let compact: Bool
    let lang: Lang
    var captionVisible = true
    /// Paused in the background (#952): playable, so not dimmed, with "Paused" on top.
    var paused = false
    /// A grid (all games, the search) has no big title above it: every tile keeps its caption, the focused one in full white.
    var alwaysCaptioned = false
    private var badge: String? {
        if paused { return L10n.string("console.paused", lang) }
        if game.status == .ready, game.olderTools { return L10n.string("library.olderToolsShort", lang) }   // why a ready game needs attention
        return game.status == .ready ? nil : L10n.string(game.status.labelKey, lang)
    }
    /// Darkening, never transparency: over the bright backdrop a see-through tile reads as a pale veil. A game this Mac cannot play is
    /// darker, a tile out of focus slightly darker on the home screen.
    /// The layer is blended in linear light, so a share that looks like half as bright is larger than a half: black at 0.5 only takes
    /// white down to a light grey (the pale veil seen on bright covers).
    private var shade: Double {
        let unplayable = game.status == .ready ? 0 : 0.72
        let unfocused = selected || alwaysCaptioned ? 0 : 0.3
        return game.status == .ready ? unfocused : max(unplayable, 0.72)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // not playable on this Mac or out of focus: darker under a black layer in the tile's own group, never see-through
            ZStack {
                ConsoleArtwork(image: game.artwork, title: game.title, focus: game.artworkFocus)
                Color.black.opacity(shade)
            }
            .compositingGroup()
            .aspectRatio(1.8, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if let badge {
                        Text(badge).font(.manrope(compact ? 14 : 18, .semibold))
                            .foregroundStyle(paused ? LauncherPalette.cream : .white)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(LauncherPalette.background.opacity(0.93), in: Capsule()).padding(14)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            // The focused game's name is the big title above, so its tile shows the image alone (the row is top-aligned, so
            // nothing else moves). The others keep a small, muted caption.
            if !selected || alwaysCaptioned {
                Text(game.title).opacity(captionVisible ? 1 : 0).font(.manrope(compact ? 14 : 17, .medium)).lineLimit(1)
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.72)).padding(.horizontal, 4).accessibilityHidden(true)
            }
        }
    }
}
