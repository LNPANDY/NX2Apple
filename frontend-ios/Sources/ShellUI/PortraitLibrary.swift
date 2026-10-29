import SwiftUI

/// The library when it is taller than it is wide: the chosen game's art as a full-bleed hero with the title over it,
/// then the collection, then recently played. In one column the primary action sits at the bottom for the thumb.
/// Beside the settings pane (two panes) the collection becomes a grid and Play moves into the hero.
struct PortraitLibrary: View {
    let games: [GameDetail]
    let selected: GameDetail
    let twoPanes: Bool
    let size: CGSize
    let topInset: CGFloat
    let controllers: Int
    let select: (String) -> Void
    let primary: (GameDetail) -> Void
    let openSettings: () -> Void
    let openControllers: () -> Void
    @Binding var position: ScrollPosition
    @Environment(\.shellFocus) private var focus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A short screen (the folded foldable is about 1.4:1) gets a smaller hero and smaller covers, so the hero,
    /// the row and Play all fit without scrolling.
    private var short: Bool { size.height + topInset < 700 }
    private var heroHeight: CGFloat {
        let tall = size.height + topInset
        return twoPanes ? min(size.width * 0.95, tall * 0.5) : min(size.width * 1.02, tall * (short ? 0.44 : 0.52))
    }
    /// Whole covers and a third of the next one: the row shows it scrolls, and the edge cuts through a cover,
    /// never through a name or a status.
    private var coverSize: CGFloat {
        let target: CGFloat = typeSize.isAccessibilitySize ? 170 : short ? 100 : 128
        let available = size.width - 24
        let whole = max(1, ((available + 16) / (target + 16)).rounded(.down))
        return available / (whole + 0.34) - 16
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HeroView(game: selected.game, height: heroHeight, topInset: topInset,
                             titleSize: twoPanes ? 36 : short ? 28 : 34) {
                        if twoPanes {
                            Button { primary(selected) } label: {
                                Label(selected.game.state.actionTitle, systemImage: selected.game.state.actionSymbol)
                            }
                            .buttonStyle(PrimaryPillStyle())
                            .accessibilityLabel(selected.game.state.actionTitle + ", " + selected.game.title)
                            .accessibilityIdentifier("state.action")
                            .shellTarget("lib.play", radius: 25) { primary(selected) }
                            .padding(.top, 8)
                        }
                    }
                    collection.padding(.top, short ? 6 : 14)
                    recent.padding(.top, 34)
                }.padding(.bottom, 28)
            }
            .scrollPosition($position)
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) { if !twoPanes { bottomBar } }
            .overlay(alignment: .topTrailing) {
                ControllerChip(count: controllers, action: openControllers).padding(.top, 6).padding(.trailing, 16)
            }
            .onChange(of: focus.id) { _, id in
                guard let id, id.hasPrefix("lib.tile.") || id.hasPrefix("lib.recent.") else { return }
                let target = id.hasPrefix("lib.tile.") ? String(id.dropFirst("lib.tile.".count)) : id
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: ShellStrings.text("Your games"), trailing: "\(games.count)").padding(.horizontal, 24)
            if twoPanes {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 180), spacing: 18, alignment: .top)],
                          alignment: .leading, spacing: 24) {
                    ForEach(games) { tile($0) }
                }.padding(.horizontal, 24)
            } else {
                ScrollView(.horizontal) {
                    // Not lazy: every cover is a focus target, so the D-pad can reach the ones still off screen.
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(games) { tile($0).frame(width: coverSize) }
                    }.scrollTargetLayout().padding(.horizontal, 24).padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.92),
                                           .init(color: .black.opacity(0), location: 1)], startPoint: .leading, endPoint: .trailing)
                }
                .padding(.vertical, -6)
            }
        }
    }

    private func tile(_ detail: GameDetail) -> some View {
        let chosen = detail.id == selected.id
        return Button { select(detail.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                CoverView(game: detail.game)
                    .shellTarget("lib.tile.\(detail.id)") { primary(detail) }
                Text(detail.game.title).shellText(13.5, .semibold).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .foregroundStyle(.white.opacity(chosen ? 1 : 0.86))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                StatusLabel(state: detail.game.state).padding(.top, 4)
                // The Mac's selection mark: a cream bar under the chosen game.
                Capsule().fill(ShellPalette.cream).frame(height: 3).padding(.top, 10).opacity(chosen ? 1 : 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detail.game.title + ", " + detail.game.state.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("tile.\(detail.id)")
        .id(detail.id)
    }

    @ViewBuilder private var recent: some View {
        let recent = games.filter { $0.game.recentlyPlayed != nil }
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: ShellStrings.text("Recently played")).padding(.bottom, 8)
                ForEach(recent) { detail in
                    Button { select(detail.id) } label: {
                        HStack(spacing: 14) {
                            CoverView(game: detail.game, radius: 8).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(detail.game.title).shellText(15, .semibold).multilineTextAlignment(.leading)
                                Text(detail.game.recentlyPlayed ?? "").shellText(12.5).foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.28)).accessibilityHidden(true)
                        }.frame(minHeight: 60).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .shellTarget("lib.recent.\(detail.id)") { select(detail.id) }
                    .id("lib.recent.\(detail.id)")
                    if detail.id != recent.last?.id { Rectangle().fill(ShellPalette.hairline).frame(height: 1).padding(.leading, 58) }
                }
            }.padding(.horizontal, 24)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { primary(selected) } label: {
                Label(selected.game.state.actionTitle, systemImage: selected.game.state.actionSymbol)
            }
            .buttonStyle(PrimaryPillStyle(expands: true))
            .accessibilityLabel(selected.game.state.actionTitle + ", " + selected.game.title)
            .accessibilityIdentifier("state.action")
            .shellTarget("lib.play", radius: 25) { primary(selected) }
            Button(action: openSettings) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(RoundIconButtonStyle())
                .accessibilityLabel(ShellStrings.text("Game settings"))
                .accessibilityIdentifier("settings.open")
                .shellTarget("lib.settings", radius: 25, action: openSettings)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 8)
        .background {
            LinearGradient(stops: [.init(color: ShellPalette.background.opacity(0), location: 0),
                                   .init(color: ShellPalette.background, location: 0.4)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// The chosen game's art edge to edge, darkened toward the type, with the state, the title and what to do next.
struct HeroView<Accessory: View>: View {
    let game: GameTile
    let height: CGFloat
    let topInset: CGFloat
    var titleSize: CGFloat = 34
    @ViewBuilder let accessory: () -> Accessory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusLabel(state: game.state, prominent: true)
            Text(game.title).shellText(titleSize, .heavy, relativeTo: .largeTitle).tracking(-titleSize * 0.03)
                .lineLimit(3).minimumScaleFactor(0.75).fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.35), radius: 14)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("hero.title")
            if !meta.isEmpty {
                Text(meta).shellText(13).foregroundStyle(.white.opacity(0.62))
            }
            if !game.state.explanation.isEmpty {
                Text(game.state.explanation).shellText(14.5).foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            }
            accessory()
        }
        .padding(.horizontal, 24).padding(.top, topInset + 64).padding(.bottom, 14)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
        .background {
            ZStack {
                // Key art is made to sit behind a title. An icon carries its own lettering, which must not compete
                // with the shell's title: it is softened, enlarged and darkened further.
                ArtView(art: game.heroArt ?? game.cover, title: game.title, seed: game.id, lettering: false)
                    .blur(radius: iconOnly ? 14 : 0, opaque: true)
                    .scaleEffect(iconOnly ? 1.15 : 1)
                    .overlay { if iconOnly { Color.black.opacity(0.22) } }
                    .id(game.id).transition(.opacity)
                // Clear only in the upper part: the type below must win over whatever lettering the art has.
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                       .init(color: .clear, location: 0.2),
                                       .init(color: .clear, location: 0.32),
                                       .init(color: .black.opacity(0.55), location: 0.58),
                                       .init(color: ShellPalette.background.opacity(0.94), location: 0.82),
                                       .init(color: ShellPalette.background, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
            }
            .animation(reduceMotion ? .linear(duration: 0.15) : .easeInOut(duration: 0.35), value: game.id)
            .accessibilityHidden(true)
        }
        .clipped()
    }

    private var iconOnly: Bool { game.heroArt == nil && game.cover != nil }

    private var meta: String {
        [game.subtitle, game.recentlyPlayed ?? ""].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }
}
