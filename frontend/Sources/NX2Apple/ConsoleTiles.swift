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
    /// A cover of the home row: the focused one is a little larger. Flat, in a straight row, no fan or tilt.
    var homeRow = false
    var showsSelection = true
    var launchNamespace: Namespace.ID? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var artworkState: LibraryArtworkState { LibraryArtworkState(game) }
    /// nxkit built it without a game profile (v0lumehi/nxkit#54): a quiet neutral chip, before Different tools, since the game may not
    /// start at all.
    private var generic: Bool { !paused && game.status == .ready && game.genericBuild != nil }
    private var badgeKey: String? {
        if paused { return "console.paused" }
        if generic { return "nxkit.generic.badge" }
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
                                      symbol: paused || generic || game.olderTools ? nil : artworkState.symbol,
                                      color: paused ? LauncherPalette.cream : (generic ? ArtworkStatusChip.neutralColor
                                          : (game.olderTools ? LauncherPalette.building : artworkState.color)),
                                      fontSize: compact ? 14 : 15, showsIndicator: !generic)
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let built = game.activeEngineBadgeName {
                    DSTag(built, emphasized: true, width: DSTag.engineWidth)
                        .padding(8)
                } else if !game.tunedEngineNames.isEmpty {
                    DSTag(L10n.string("library.chip.tunedAvailable", lang), emphasized: true)
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Console.Radius.art))
            .overlay(RoundedRectangle(cornerRadius: DS.Console.Radius.art).strokeBorder(selected && showsSelection ? DS.Color.accent : DS.Color.separator,
                                                                                    lineWidth: selected && showsSelection ? DS.Console.Control.focusRing : 1))
            // Flat covers in a straight row: the focused one on the home row grows by DS.Console.Scale.focus, the others stay as they are.
            .scaleEffect(homeRow && selected && !reduceMotion ? DS.Console.Scale.focus : 1)
            .modifier(ConsoleLaunchArtwork(namespace: launchNamespace, id: game.id))
            .dsAnimation(ConsoleHomeMotion.tileFocus(homeRow: homeRow, reduceMotion: reduceMotion), value: selected)
            // Every cover has its title under it, the art stays clean: the focused one in the primary text, the others secondary. The
            // home row hides the captions of the covers already passed and of those cut off at the edge.
            Text(game.title).opacity(captionVisible ? 1 : 0)
                .font(DS.Console.Font.callout).lineLimit(1)
                .foregroundStyle(selected ? DS.Color.textPrimary : DS.Color.textSecondary)
                .padding(.horizontal, DS.Space.xxs).accessibilityHidden(true)
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

/// The starting screen's progress, always labelled: "Compiling shaders · 18 of 48" over a thin bar filled to the measured share, or
/// "Starting…" over a short segment that slides along the bar while nothing is measured (the old capsule showed that fill without a
/// label and read as a broken control).
struct ConsoleLaunchProgress: View {
    let progress: Double?
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the sliding segment is, 0 to 1, every two seconds. Reduced Motion holds it in the middle.
    static func phase(at date: Date, reducedMotion: Bool) -> Double {
        reducedMotion ? 0.5 : date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Console.Space.s) {
            HStack {
                Text(label).font(DS.Console.Font.body).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                Spacer(minLength: DS.Console.Space.s)
                if let progress {
                    Text("\(Int((ConsoleValueBar.clamped(progress) * 100).rounded())) %").font(DS.Console.Font.body)
                        .foregroundStyle(DS.Color.textSecondary).monospacedDigit()
                }
            }
            if let progress {
                ConsoleProgressBar(fraction: progress, height: 6)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                    let phase = Self.phase(at: timeline.date, reducedMotion: reduceMotion)
                    GeometryReader { g in
                        let segment = g.size.width * 0.28
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.Color.separator)
                            Capsule().fill(DS.Color.accent).frame(width: segment).offset(x: (g.size.width - segment) * phase)
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
        .accessibilityValue(progress.map { "\(Int(ConsoleValueBar.clamped($0) * 100))%" } ?? "")
    }
}
