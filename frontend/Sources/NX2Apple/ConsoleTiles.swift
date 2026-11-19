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
    var coverflow = false
    var tilt: Double = 0
    var rearOffset: CGFloat = 0
    var showsSelection = true
    var launchNamespace: Namespace.ID? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var artworkState: LibraryArtworkState { LibraryArtworkState(game) }
    private var badgeKey: String? {
        if paused { return "console.paused" }
        if game.status == .ready, game.olderTools { return "library.olderToolsShort" }
        return artworkState.chipKey
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                ConsoleArtwork(image: game.artwork, title: game.title, focus: game.artworkFocus)
                    .saturation(LibraryArtworkTone.saturation(muted: game.needsMutedArtworkTone, active: selected))
                    .drawingGroup()
                Color.black.opacity(selected ? 0 : 0.55)
            }
            .compositingGroup()
            .aspectRatio(1.8, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                if let key = badgeKey {
                    ArtworkStatusChip(title: L10n.string(key, lang),
                                      symbol: paused || game.olderTools ? nil : artworkState.symbol,
                                      color: paused ? LauncherPalette.cream : (game.olderTools ? LauncherPalette.building : artworkState.color),
                                      fontSize: compact ? 14 : 15)
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected && showsSelection ? LauncherPalette.cream : .white.opacity(0.12), lineWidth: selected && showsSelection ? 4 : 1))
            .scaleEffect(coverflow && !reduceMotion ? (selected ? 1.04 : (tilt > 0 ? 0.76 : 0.96)) : 1)
            .rotation3DEffect(.degrees(coverflow && !reduceMotion ? tilt : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            .offset(x: coverflow && !reduceMotion && tilt > 0 ? rearOffset : 0,
                    y: coverflow && !reduceMotion ? (selected ? -4 : 4) : 0)
            .modifier(ConsoleLaunchArtwork(namespace: launchNamespace, id: game.id))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: selected)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: tilt)
            // The focused game's name is the big title above, so its tile shows the image alone (the row is top-aligned, so
            // nothing else moves). The others keep a small, muted caption.
            if !selected || alwaysCaptioned {
                Text(game.title).opacity(captionVisible ? 1 : 0).font(.manrope(compact ? 14 : 17, .medium)).lineLimit(1)
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.72)).padding(.horizontal, 4).accessibilityHidden(true)
            }
        }
    }
}


extension ConsoleGame {
    /// Playable builds (Mac or iPhone, regardless of older tools) keep full-color artwork; unbuilt/broken entries use the muted tone.
    var needsMutedArtworkTone: Bool { status != .ready && status != .iphoneOnly }
}

extension LibraryArtworkState {
    /// The console driver already verified availability. Rendering never probes the filesystem.
    init(_ game: ConsoleGame) {
        let attention: Attention
        switch game.status {
        case .ready, .iphoneOnly: attention = .none
        case .needsBuild: attention = .notBuilt
        case .needsData: attention = .missingData
        case .broken: attention = .fixFiles
        }
        self.init(mac: game.status == .ready, ios: game.status == .iphoneOnly || game.platforms.contains(.iphone), attention: attention)
    }
}

struct ConsoleLaunchArtwork: ViewModifier {
    let namespace: Namespace.ID?
    let id: String
    @ViewBuilder func body(content: Content) -> some View {
        if let namespace { content.matchedGeometryEffect(id: id, in: namespace) }
        else { content }
    }
}

/// Measured shader work fills the capsule. Unmeasured phases repeat a leading-edge fill without a percentage.
struct ConsoleLaunchProgress: View {
    let progress: Double?
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static func phase(at date: Date, reducedMotion: Bool) -> Double {
        reducedMotion ? 0.5 : date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
    }
    var body: some View {
        GeometryReader { bounds in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.65))
                if let progress {
                    Rectangle().fill(LauncherPalette.cream)
                        .frame(width: bounds.size.width * min(max(progress, 0), 1))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: progress)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                        let phase = Self.phase(at: timeline.date, reducedMotion: reduceMotion)
                        Rectangle().fill(LauncherPalette.cream)
                            .frame(width: bounds.size.width * phase)
                            .opacity(reduceMotion || phase < 0.8 ? 1 : (1 - phase) / 0.2)
                            .frame(width: bounds.size.width, height: bounds.size.height, alignment: .leading)
                    }
                }
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(LauncherPalette.cream.opacity(0.35), lineWidth: 1))
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
        .accessibilityValue(progress.map { "\(Int(min(max($0, 0), 1) * 100))%" } ?? "")
    }
}
