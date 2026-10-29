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
    @State private var rowID: String?
    /// Set while the row itself chose the game, so it does not scroll under the finger.
    @State private var rowSelecting = false
    @Environment(\.shellFocus) private var focus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A short screen (the folded foldable is about 1.4:1) gets a smaller hero and smaller covers, so the hero,
    /// the row and Play all fit without scrolling.
    private var short: Bool { size.height + topInset < 700 }
    /// Whole cards only, the gap as wide as the margin: the next card starts exactly at the screen edge, so the edge
    /// falls between cards and never through a name or a status. Long names end in an ellipsis inside their card.
    private var coverSize: CGFloat {
        let target: CGFloat = typeSize.isAccessibilitySize ? 300 : short ? 140 : 160
        let available = size.width - 48
        let count = max(1, ((available + 24) / (target + 24)).rounded(.down))
        return (available - (count - 1) * 24) / count
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HeroView(game: selected.game, width: size.width, topInset: topInset,
                             titleSize: twoPanes ? 34 : short ? 26 : 32) {
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 18, alignment: .top)],
                          alignment: .leading, spacing: 24) {
                    ForEach(games) { tile($0) }
                }.padding(.horizontal, 24)
            } else {
                ScrollView(.horizontal) {
                    // Not lazy: every cover is a focus target, so the D-pad can reach the ones still off screen.
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(games) { tile($0).frame(width: coverSize) }
                    }.scrollTargetLayout().padding(.vertical, 6)
                }
                .contentMargins(.horizontal, 24, for: .scrollContent)
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $rowID, anchor: .leading)
                // A game chosen elsewhere (at launch, in Recently played, after a fold) comes into view.
                .onAppear { rowID = selected.id }
                .onChange(of: selected.id) { _, id in
                    guard !rowSelecting else { rowSelecting = false; return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { rowID = id }
                }
                .padding(.vertical, -6)
            }
        }
    }

    private func tile(_ detail: GameDetail) -> some View {
        let chosen = detail.id == selected.id
        return Button { rowSelecting = !chosen; select(detail.id) } label: {
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
                            CoverView(game: detail.game, radius: 6).frame(width: 78, height: 44)
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
                    if detail.id != recent.last?.id { Rectangle().fill(ShellPalette.hairline).frame(height: 1).padding(.leading, 92) }
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

/// The chosen game's banner, whole and edge to edge at the top, flowing into a blurred copy of itself where the
/// state, the title and what to do next sit. The banner's own logo and the shell's title never overlap.
struct HeroView<Accessory: View>: View {
    let game: GameTile
    let width: CGFloat
    let topInset: CGFloat
    var titleSize: CGFloat = 34
    @ViewBuilder let accessory: () -> Accessory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let bannerHeight = width * 9 / 16
        VStack(alignment: .leading, spacing: 10) {
            StatusLabel(state: game.state, prominent: true)
            Text(game.title).shellText(titleSize, .heavy, relativeTo: .largeTitle).tracking(-titleSize * 0.03)
                .lineLimit(3).minimumScaleFactor(0.75).fixedSize(horizontal: false, vertical: true)
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
        .padding(.horizontal, 24)
        .padding(.top, max(topInset, bannerHeight - 26))
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .background {
            ZStack(alignment: .top) {
                ArtView(game: game, backdrop: true)
                    .scaleEffect(1.4)
                    .blur(radius: 50, opaque: true)
                    .saturation(1.2)
                    .overlay(Color.black.opacity(0.35))
                ArtView(game: game, lettering: false)
                    .frame(width: width, height: bannerHeight)
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.72),
                                               .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                    }
                LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0),
                                       .init(color: .clear, location: min(0.3, (topInset + 40) / max(1, bannerHeight * 2)))],
                               startPoint: .top, endPoint: .bottom)
                // The blurred colour settles into the page at the bottom edge.
                LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: ShellPalette.background, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .id(game.id).transition(.opacity)
            .animation(reduceMotion ? .linear(duration: 0.15) : .easeInOut(duration: 0.35), value: game.id)
            .accessibilityHidden(true)
        }
        .clipped()
    }

    private var meta: String {
        [game.subtitle, game.recentlyPlayed ?? ""].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }
}
