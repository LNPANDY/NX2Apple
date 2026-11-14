import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Pure SwiftUI presentation for every Home Screen, iPad Pro Command Deck, StandBy, and Lock Screen widget family.
public struct ShellWidgetView: View {
    public let snapshot: ShellWidgetSnapshot
    public let family: ShellWidgetFamily
    public let filter: ShellWidgetFilter
    public let tapBehavior: ShellWidgetTapBehavior

    public init(
        snapshot: ShellWidgetSnapshot,
        family: ShellWidgetFamily,
        filter: ShellWidgetFilter = .all,
        tapBehavior: ShellWidgetTapBehavior = .launch
    ) {
        self.snapshot = snapshot
        self.family = family
        self.filter = filter
        self.tapBehavior = tapBehavior
    }

    public var body: some View {
        switch family {
        case .small:
            if let hero = snapshot.games.first {
                SmallWidgetCard(game: hero, tapBehavior: tapBehavior)
            } else {
                EmptySystemWidget(compact: true)
            }
        case .medium:
            if let hero = snapshot.games.first {
                MediumWidgetDeck(
                    hero: hero,
                    upNext: Array(snapshot.games.dropFirst().prefix(2)),
                    readyCount: snapshot.readyCount,
                    filter: filter,
                    tapBehavior: tapBehavior
                )
            } else {
                EmptySystemWidget(compact: false)
            }
        case .large:
            if let hero = snapshot.games.first {
                LargeWidgetShelf(
                    hero: hero,
                    gridGames: Array(snapshot.games.dropFirst().prefix(4)),
                    readyCount: snapshot.readyCount,
                    filter: filter,
                    tapBehavior: tapBehavior
                )
            } else {
                EmptySystemWidget(compact: false)
            }
        case .extraLarge:
            if let hero = snapshot.games.first {
                ExtraLargeCommandDeck(
                    hero: hero,
                    gridGames: Array(snapshot.games.dropFirst().prefix(6)),
                    readyCount: snapshot.readyCount,
                    filter: filter,
                    tapBehavior: tapBehavior
                )
            } else {
                EmptySystemWidget(compact: false)
            }
        case .accessoryRectangular:
            AccessoryRectangularCard(snapshot: snapshot)
        case .accessoryCircular:
            AccessoryCircularBadge(snapshot: snapshot)
        case .accessoryInline:
            AccessoryInlineLabel(snapshot: snapshot)
        }
    }
}

/// Ambient obsidian backdrop with a subtle glow sampled from the featured game's artwork tone.
public struct ShellWidgetBackdrop: View {
    public let snapshot: ShellWidgetSnapshot

    public init(snapshot: ShellWidgetSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        let tone = (snapshot.games.first?.banner ?? snapshot.games.first?.icon)?.tone ?? (red: 0.18, green: 0.16, blue: 0.20)
        let glow = Color(
            red: min(1, tone.red * 1.15 + 0.08),
            green: min(1, tone.green * 1.15 + 0.07),
            blue: min(1, tone.blue * 1.15 + 0.09)
        )
        ZStack {
            ShellPalette.background
            RadialGradient(
                colors: [glow.opacity(0.28), glow.opacity(0.08), .clear],
                center: .topLeading,
                startRadius: 8,
                endRadius: 340
            )
            LinearGradient(
                colors: [.white.opacity(0.045), .clear],
                startPoint: .top,
                endPoint: .init(x: 0.5, y: 0.18)
            )
        }
    }
}

// MARK: - System Small ("Continue Playing" Poster)

private struct SmallWidgetCard: View {
    let game: ShellWidgetGame
    let tapBehavior: ShellWidgetTapBehavior

    var body: some View {
        Link(destination: game.primaryURL(behavior: tapBehavior)) {
            ZStack {
                WidgetArt(game: game)
                WidgetCinemaScrim(bottomStrength: 0.92)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 6) {
                        if game.isSwitch2 {
                            WidgetSwitch2Pill(compact: true)
                        } else {
                            StateDot(state: game.state, size: 8)
                        }
                        Spacer(minLength: 4)
                        WidgetPlayCircle(playable: game.isPlayable, size: 28)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(eyebrow.uppercased())
                            .font(ShellFonts.fixed(9.5, weight: .bold))
                            .tracking(0.9)
                            .foregroundStyle(ShellPalette.cream.opacity(0.86))
                            .lineLimit(1)
                            .widgetAccentableIfAvailable()
                        Text(game.title)
                            .font(ShellFonts.fixed(14.5, weight: .heavy))
                            .tracking(-0.3)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    }
                }
                .padding(13)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(ContainerRelativeShape().strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ShellWidgetStrings.playAccessibility(game.title))
    }

    private var eyebrow: String {
        if let recent = game.recentlyPlayed, !recent.isEmpty { return recent }
        return game.state.title
    }
}

// MARK: - System Medium ("Console Deck")

private struct MediumWidgetDeck: View {
    let hero: ShellWidgetGame
    let upNext: [ShellWidgetGame]
    let readyCount: Int
    let filter: ShellWidgetFilter
    let tapBehavior: ShellWidgetTapBehavior

    var body: some View {
        GeometryReader { geo in
            let hasRail = !upNext.isEmpty
            let spacing: CGFloat = 10
            let heroWidth = hasRail ? floor((geo.size.width - spacing) * 0.47) : geo.size.width
            HStack(spacing: spacing) {
                Link(destination: hero.primaryURL(behavior: tapBehavior)) {
                    ZStack {
                        WidgetArt(game: hero)
                        WidgetCinemaScrim(bottomStrength: 0.92)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                if hero.isSwitch2 {
                                    WidgetSwitch2Pill(compact: true)
                                } else {
                                    StateDot(state: hero.state, size: 8)
                                }
                                Spacer(minLength: 4)
                            }
                            Spacer(minLength: 6)
                            HStack(alignment: .bottom, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(heroSubtitle)
                                        .font(ShellFonts.fixed(9.5, weight: .semibold))
                                        .foregroundStyle(ShellPalette.cream.opacity(0.80))
                                        .lineLimit(1)
                                    Text(hero.title)
                                        .font(ShellFonts.fixed(14, weight: .heavy))
                                        .tracking(-0.3)
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 2)
                                WidgetPlayCircle(playable: hero.isPlayable, size: 28)
                            }
                        }
                        .padding(11)
                    }
                    .frame(width: heroWidth, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)

                if hasRail {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(railTitle.uppercased())
                                .font(ShellFonts.fixed(9.5, weight: .bold))
                                .tracking(1.2)
                                .foregroundStyle(ShellPalette.cream.opacity(0.76))
                                .lineLimit(1)
                                .widgetAccentableIfAvailable()
                            Spacer(minLength: 4)
                            Text(ShellWidgetStrings.readyCount(readyCount))
                                .font(ShellFonts.fixed(9.5, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 2)

                        ForEach(upNext) { item in
                            WidgetRailRow(game: item, tapBehavior: tapBehavior)
                        }
                        if upNext.count == 1 {
                            WidgetLibraryFallbackRow()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(12)
    }

    private var heroSubtitle: String {
        if let recent = hero.recentlyPlayed, !recent.isEmpty { return recent }
        return hero.state.title
    }

    private var railTitle: String {
        filter == .switch2 ? ShellStrings.text("Switch 2") : ShellWidgetStrings.upNext
    }
}

private struct WidgetRailRow: View {
    let game: ShellWidgetGame
    let tapBehavior: ShellWidgetTapBehavior

    var body: some View {
        Link(destination: game.primaryURL(behavior: tapBehavior)) {
            HStack(spacing: 7) {
                WidgetSquareThumb(game: game)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.8))

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(game.title)
                        .font(ShellFonts.fixed(11.5, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)
                    Text(game.compactSubtitle)
                        .font(ShellFonts.fixed(9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Image(systemName: game.isPlayable ? "play.fill" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(game.isPlayable ? ShellPalette.cream.opacity(0.9) : .white.opacity(0.4))
                    .widgetAccentableIfAvailable()
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ShellPalette.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(ShellPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct WidgetLibraryFallbackRow: View {
    var body: some View {
        Link(destination: ShellDeepLink.library.url) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ShellPalette.cream.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(ShellStrings.text("Your games"))
                    .font(ShellFonts.fixed(11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ShellPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(ShellPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - System Large ("Console Shelf" — Hero + 2x2 16:9 Grid)

private struct LargeWidgetShelf: View {
    let hero: ShellWidgetGame
    let gridGames: [ShellWidgetGame]
    let readyCount: Int
    let filter: ShellWidgetFilter
    let tapBehavior: ShellWidgetTapBehavior

    var body: some View {
        GeometryReader { geo in
            let hasGrid = !gridGames.isEmpty
            let heroHeight = hasGrid ? floor(geo.size.height * 0.49) : geo.size.height
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Link(destination: hero.primaryURL(behavior: tapBehavior)) {
                        ZStack {
                            WidgetArt(game: hero)
                            WidgetCinemaScrim(bottomStrength: 0.93)
                        }
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            if hero.isSwitch2 {
                                WidgetSwitch2Pill(compact: false)
                            } else {
                                WidgetEyebrowChip(text: headerEyebrow)
                            }
                            Spacer(minLength: 6)
                            WidgetReadyPill(readyCount: readyCount)
                        }
                        Spacer(minLength: 8)
                        HStack(alignment: .bottom, spacing: 10) {
                            Link(destination: hero.primaryURL(behavior: tapBehavior)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hero.title)
                                        .font(ShellFonts.fixed(19, weight: .heavy))
                                        .tracking(-0.45)
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                                    Text(hero.metaLine)
                                        .font(ShellFonts.fixed(11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.68))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)

                            HStack(spacing: 6) {
                                Link(destination: hero.settingsURL) {
                                    WidgetIconCircle(symbol: "slider.horizontal.3", size: 34)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(ShellStrings.text("Game settings"))

                                Link(destination: hero.playURL) {
                                    WidgetPlayCapsule(playable: hero.isPlayable, compact: false)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(ShellWidgetStrings.playAccessibility(hero.title))
                            }
                        }
                    }
                    .padding(13)
                }
                .frame(width: geo.size.width, height: heroHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))

                if hasGrid {
                    HStack(alignment: .center, spacing: 8) {
                        Text(ShellWidgetStrings.upNext.uppercased())
                            .font(ShellFonts.fixed(10, weight: .bold))
                            .tracking(1.4)
                            .foregroundStyle(ShellPalette.cream.opacity(0.76))
                            .widgetAccentableIfAvailable()
                        Spacer(minLength: 8)
                        Link(destination: ShellDeepLink.controllers.url) {
                            HStack(spacing: 4) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text(ShellStrings.text("Controllers"))
                                    .font(ShellFonts.fixed(10, weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.58))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 2)

                    WidgetCoverGrid(games: gridGames, columns: 2, rows: 2, tapBehavior: tapBehavior)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(14)
    }

    private var headerEyebrow: String {
        filter == .switch2 ? ShellWidgetStrings.switch2Title : ShellWidgetStrings.continueTitle
    }
}

// MARK: - System Extra Large ("iPad Pro Command Deck" — Hero + 3x2 6-Game Wall)

private struct ExtraLargeCommandDeck: View {
    let hero: ShellWidgetGame
    let gridGames: [ShellWidgetGame]
    let readyCount: Int
    let filter: ShellWidgetFilter
    let tapBehavior: ShellWidgetTapBehavior

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 14
            let hasGrid = !gridGames.isEmpty
            let heroWidth = hasGrid ? floor((geo.size.width - spacing) * 0.38) : geo.size.width
            HStack(spacing: spacing) {
                VStack(alignment: .leading, spacing: 0) {
                    Link(destination: hero.primaryURL(behavior: tapBehavior)) {
                        ZStack(alignment: .topLeading) {
                            WidgetArt(game: hero)
                            LinearGradient(
                                stops: [
                                    .init(color: .black.opacity(0.28), location: 0),
                                    .init(color: .clear, location: 0.30),
                                    .init(color: ShellPalette.surface.opacity(0.35), location: 0.78),
                                    .init(color: ShellPalette.surface, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            HStack(spacing: 6) {
                                if hero.isSwitch2 {
                                    WidgetSwitch2Pill(compact: false)
                                } else {
                                    StateDot(state: hero.state, size: 9)
                                }
                                Spacer(minLength: 4)
                            }
                            .padding(12)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 10) {
                        Link(destination: hero.primaryURL(behavior: tapBehavior)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(hero.title)
                                    .font(ShellFonts.fixed(20, weight: .heavy))
                                    .tracking(-0.48)
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(hero.metaLine)
                                    .font(ShellFonts.fixed(11.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.62))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 8) {
                            Link(destination: hero.playURL) {
                                WidgetPlayCapsule(playable: hero.isPlayable, compact: false, expands: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(ShellWidgetStrings.playAccessibility(hero.title))

                            Link(destination: hero.settingsURL) {
                                WidgetIconCircle(symbol: "slider.horizontal.3", size: 36)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(ShellStrings.text("Game settings"))

                            Link(destination: ShellDeepLink.controllers.url) {
                                WidgetIconCircle(symbol: "gamecontroller.fill", size: 36)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(ShellStrings.text("Controllers"))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .padding(.top, 4)
                    .background(ShellPalette.surface)
                }
                .frame(width: heroWidth, height: geo.size.height)
                .background(ShellPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))

                if hasGrid {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 8) {
                            Text(shelfHeading.uppercased())
                                .font(ShellFonts.fixed(10.5, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(ShellPalette.cream.opacity(0.78))
                                .widgetAccentableIfAvailable()
                            Spacer(minLength: 8)
                            WidgetReadyPill(readyCount: readyCount)
                        }
                        .padding(.horizontal, 2)

                        WidgetCoverGrid(games: gridGames, columns: 3, rows: 2, tapBehavior: tapBehavior)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(16)
    }

    private var shelfHeading: String {
        filter == .switch2 ? ShellWidgetStrings.switch2Title : ShellStrings.text("Your games")
    }
}

// MARK: - Cover Grid Shared by Large (2x2) and ExtraLarge (3x2)

private struct WidgetCoverGrid: View {
    let games: [ShellWidgetGame]
    let columns: Int
    let rows: Int
    let tapBehavior: ShellWidgetTapBehavior

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 9
            let cellWidth = max(40, (geo.size.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
            let cellHeight = max(36, (geo.size.height - CGFloat(rows - 1) * gap) / CGFloat(rows))
            VStack(alignment: .leading, spacing: gap) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<columns, id: \.self) { col in
                            let index = row * columns + col
                            if games.indices.contains(index) {
                                WidgetGridCard(game: games[index], tapBehavior: tapBehavior)
                                    .frame(width: cellWidth, height: cellHeight)
                            } else {
                                WidgetEmptySlotCard()
                                    .frame(width: cellWidth, height: cellHeight)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct WidgetGridCard: View {
    let game: ShellWidgetGame
    let tapBehavior: ShellWidgetTapBehavior

    var body: some View {
        Link(destination: game.primaryURL(behavior: tapBehavior)) {
            ZStack {
                WidgetArt(game: game)
                WidgetCinemaScrim(bottomStrength: 0.88)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        if game.isSwitch2 {
                            WidgetSwitch2Pill(compact: true)
                        } else {
                            StateDot(state: game.state, size: 7)
                        }
                        Spacer(minLength: 2)
                    }
                    Spacer(minLength: 4)
                    HStack(alignment: .bottom, spacing: 5) {
                        Text(game.title)
                            .font(ShellFonts.fixed(11, weight: .bold))
                            .tracking(-0.2)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.88)
                            .multilineTextAlignment(.leading)
                            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                        Spacer(minLength: 2)
                        if game.isPlayable {
                            Image(systemName: "play.fill")
                                .font(.system(size: 7.5, weight: .black))
                                .foregroundStyle(.black)
                                .frame(width: 17, height: 17)
                                .background(ShellPalette.cream, in: Circle())
                                .widgetAccentableIfAvailable()
                        }
                    }
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.11), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ShellWidgetStrings.playAccessibility(game.title))
    }
}

private struct WidgetEmptySlotCard: View {
    var body: some View {
        Link(destination: ShellDeepLink.library.url) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(ShellPalette.surface.opacity(0.55))
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(ShellPalette.hairline, lineWidth: 1)
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10, weight: .semibold))
                    Text(ShellStrings.text("Library"))
                        .font(ShellFonts.fixed(10.5, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.38))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Lock Screen & StandBy Accessory Families

private struct AccessoryRectangularCard: View {
    let snapshot: ShellWidgetSnapshot

    var body: some View {
        if let hero = snapshot.games.first {
            Link(destination: hero.playURL) {
                HStack(spacing: 8) {
                    WidgetSquareThumb(game: hero)
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.8))

                    VStack(alignment: .leading, spacing: 1.5) {
                        HStack(spacing: 4) {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 8.5, weight: .bold))
                            Text((hero.isSwitch2 ? ShellStrings.text("Switch 2") : ShellWidgetStrings.continueTitle).uppercased())
                                .font(ShellFonts.fixed(8.5, weight: .bold))
                                .tracking(0.8)
                        }
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .widgetAccentableIfAvailable()

                        Text(hero.title)
                            .font(ShellFonts.fixed(12, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Text(hero.recentlyPlayed ?? hero.state.title)
                            .font(ShellFonts.fixed(10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        } else {
            Link(destination: ShellDeepLink.library.url) {
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .widgetAccentableIfAvailable()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ShellWidgetStrings.continueTitle)
                            .font(ShellFonts.fixed(12, weight: .bold))
                        Text(ShellWidgetStrings.emptyTitle)
                            .font(ShellFonts.fixed(10, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct AccessoryCircularBadge: View {
    let snapshot: ShellWidgetSnapshot

    var body: some View {
        let target = snapshot.games.first?.playURL ?? ShellDeepLink.library.url
        Link(destination: target) {
            ZStack {
                Circle().fill(.white.opacity(0.12))
                Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1.5)
                VStack(spacing: 1) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 14, weight: .bold))
                        .widgetAccentableIfAvailable()
                    Text("\(snapshot.readyCount)")
                        .font(ShellFonts.fixed(13, weight: .heavy))
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct AccessoryInlineLabel: View {
    let snapshot: ShellWidgetSnapshot

    var body: some View {
        if let hero = snapshot.games.first {
            Label("\(hero.title) · \(ShellStrings.text("Play"))", systemImage: "gamecontroller.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Label(ShellWidgetStrings.readyCount(snapshot.readyCount), systemImage: "gamecontroller.fill")
                .labelStyle(.titleAndIcon)
        }
    }
}

// MARK: - Empty State

private struct EmptySystemWidget: View {
    let compact: Bool

    var body: some View {
        Link(destination: ShellDeepLink.library.url) {
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                HStack {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: compact ? 15 : 17, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: compact ? 30 : 34, height: compact ? 30 : 34)
                        .background(ShellPalette.cream, in: Circle())
                        .widgetAccentableIfAvailable()
                    Spacer()
                }
                Spacer(minLength: 4)
                Text(ShellWidgetStrings.emptyTitle)
                    .font(ShellFonts.fixed(compact ? 14 : 16, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !compact {
                    Text(ShellWidgetStrings.emptyNote)
                        .font(ShellFonts.fixed(12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(3)
                }
            }
            .padding(compact ? 14 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared Building Blocks

private struct WidgetArt: View {
    let game: ShellWidgetGame

    var body: some View {
        ArtView(game: game.tile, lettering: false)
    }
}

private struct WidgetSquareThumb: View {
    let game: ShellWidgetGame

    var body: some View {
        Color.clear.overlay {
            if let icon = game.icon {
                Image(decorative: icon.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else if let banner = game.banner {
                Image(decorative: banner.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                PlaceholderArt(title: game.title, seed: game.id, lettering: false)
            }
        }
        .clipped()
    }
}

private struct WidgetCinemaScrim: View {
    var bottomStrength: Double = 0.9

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.32), location: 0.0),
                .init(color: .black.opacity(0.03), location: 0.34),
                .init(color: .black.opacity(0.24), location: 0.60),
                .init(color: .black.opacity(bottomStrength * 0.84), location: 0.82),
                .init(color: .black.opacity(bottomStrength), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct WidgetSwitch2Pill: View {
    let compact: Bool

    var body: some View {
        Text(ShellStrings.text("Switch 2"))
            .font(ShellFonts.fixed(compact ? 8.5 : 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.90))
            .lineLimit(1)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2.5 : 3.5)
            .background(.black.opacity(0.82), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.36), lineWidth: 0.9))
    }
}

private struct WidgetEyebrowChip: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(ShellFonts.fixed(9, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(ShellPalette.cream.opacity(0.9))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(.black.opacity(0.58), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.8))
    }
}

private struct WidgetReadyPill: View {
    let readyCount: Int

    var body: some View {
        Link(destination: ShellDeepLink.library.url) {
            HStack(spacing: 5) {
                Circle()
                    .fill(ShellPalette.ready)
                    .frame(width: 6, height: 6)
                Text(ShellWidgetStrings.readyCount(readyCount))
                    .font(ShellFonts.fixed(10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.black.opacity(0.62), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

private struct WidgetPlayCapsule: View {
    let playable: Bool
    var compact = false
    var expands = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: playable ? "play.fill" : "folder")
                .font(.system(size: compact ? 9.5 : 11, weight: .black))
            Text(playable ? ShellStrings.text("Play") : ShellStrings.text("Choose"))
                .font(ShellFonts.fixed(compact ? 11.5 : 13, weight: .bold))
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 11 : 15)
        .frame(maxWidth: expands ? .infinity : nil)
        .frame(height: compact ? 28 : 35)
        .foregroundStyle(playable ? .black : .white)
        .background(playable ? ShellPalette.cream : .white.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(playable ? 0 : 0.2), lineWidth: 1))
        .widgetAccentableIfAvailable()
    }
}

private struct WidgetPlayCircle: View {
    let playable: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: playable ? "play.fill" : "arrow.up.forward")
            .font(.system(size: size * 0.38, weight: .black))
            .foregroundStyle(playable ? .black : .white)
            .frame(width: size, height: size)
            .background(playable ? ShellPalette.cream : .black.opacity(0.6), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(playable ? 0 : 0.22), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.32), radius: 3, y: 1)
            .widgetAccentableIfAvailable()
    }
}

private struct WidgetIconCircle: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: size, height: size)
            .background(.black.opacity(0.62), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.9))
    }
}

private extension View {
    @ViewBuilder func widgetAccentableIfAvailable() -> some View {
        #if canImport(WidgetKit)
        self.widgetAccentable()
        #else
        self
        #endif
    }
}
