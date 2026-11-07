import SwiftUI

/// A Recently played row selects its game for the shared primary action.
enum RecentRow {
    /// Space above and below the hairline between two rows, so a title never touches it.
    static let separatorGap: CGFloat = 10
    static let minHeight: CGFloat = 60
}

enum PortraitScrollDecoration: Equatable {
    case fade(CGFloat)
    case pullDown(CGFloat)
    case inactive

    static func value(offset: CGFloat, tabletop: Bool, includesHero: Bool) -> Self {
        if tabletop { return .fade(min(1, max(0, offset / 48))) }
        if includesHero { return .pullDown(max(0, -offset)) }
        return .inactive
    }
}

/// The library when it is taller than it is wide: the chosen game's banner as the hero with the title under it,
/// then the collection, then recently played. In one column the primary action sits at the bottom for the thumb.
/// With regular width (an iPad or an unfolded foldable held upright) the collection becomes a grid of wide cards and
/// the primary action remains at the bottom. Settings themselves only appear when asked for.
struct PortraitLibrary: View, Equatable {
    @Environment(\.shellNativeBars) private var nativeBars
    let games: [GameDetail]
    let selected: GameDetail
    let wide: Bool
    let size: CGSize
    let topInset: CGFloat
    /// The home indicator's height. Without a bottom bar the library scrolls under it to the bottom edge.
    var bottomInset: CGFloat = 0
    var obscured = false
    let controllers: Int
    let select: (String) -> Void
    let primary: (GameDetail) -> Void
    let openSettings: () -> Void
    let openControllers: () -> Void
    let openShellSettings: () -> Void
    @Binding var position: ScrollPosition
    @Namespace private var actionGlassNamespace
    @Namespace private var poseNamespace
    @State private var rowID: String?
    @State private var tabletop = false
    @State private var heroCollapsed = false
    @State private var heroExpansionArmed = false
    @State private var scrolling = false
    @State private var gridFade: CGFloat = 0
    @State private var heroPullDown: CGFloat = 0
    @State private var expandedScrollInset: CGFloat?
    @State private var heroCanCollapse = false
    @ScaledMetric(relativeTo: .largeTitle) private var compactHeroHeight: CGFloat = 128
    @Environment(\.shellFocus) private var focus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A short screen (the folded foldable is about 1.4:1) gets a smaller hero and smaller covers, so the hero,
    /// the row and Play all fit without scrolling.
    private var short: Bool { size.height + topInset < 700 }
    /// One height for the hero per layout, a little under half the screen, so "Your games" sits high.
    private var heroHeight: CGFloat {
        let tall = size.height + topInset
        return wide ? min(tall * 0.42, size.width * 0.62) : tall * 0.42
    }
    /// Whole cards only, the gap as wide as the margin: the next card starts exactly at the screen edge, so the edge
    /// falls between cards and never through a name or a status. Long names end in an ellipsis inside their card.
    private var coverSize: CGFloat {
        let target: CGFloat = typeSize.isAccessibilitySize ? 300 : short ? 140 : 160
        let available = max(0, size.width - 48)
        let count = max(1, ((available + 24) / (target + 24)).rounded(.down))
        return (available - (count - 1) * 24) / count
    }

    /// Re-render only for what is drawn: the games' tiles, the selection and the sizes. A setting changed in the panel
    /// above does not redraw the library underneath.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.games.map(\.game) == rhs.games.map(\.game) && lhs.selected.game == rhs.selected.game && lhs.wide == rhs.wide
            && lhs.size == rhs.size && lhs.topInset == rhs.topInset && lhs.bottomInset == rhs.bottomInset
            && lhs.controllers == rhs.controllers && lhs.obscured == rhs.obscured
    }

    private var expanded: Bool { wide || ShellLayout.resolve(size, accessibilityText: false) == .grid }
    private var collapse: CGFloat { heroCollapsed ? 1 : 0 }
    private var collapseDistance: CGFloat { max(0, heroHeight - topInset - compactHeroHeight) }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            ScrollViewReader { proxy in
                Group {
                    if #available(iOS 27.1, macOS 27.1, *), tabletop {
                        ArrangementView {
                            VStack(spacing: 0) {
                                tabletopHero
                                gridHeading
                            }
                        } secondary: {
                            gameScroll(includesHero: false)
                                .safeAreaBar(edge: .bottom, spacing: 0) { bottomBar }
                        }
                        .arrangementViewStyle(.split.axes(.vertical))
                        .background(Color.black)
                    } else if expanded {
                        // Resize the scroll viewport with the hero so newly exposed tiles also receive touches.
                        VStack(spacing: 0) {
                            expandedHero
                            gridHeading
                            gameScroll(includesHero: false)
                        }
                        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: heroCollapsed)
                        .safeAreaBar(edge: .bottom, spacing: 0) { bottomBar }
                    } else {
                        gameScroll(includesHero: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .safeAreaBar(edge: .bottom, spacing: 0) { bottomBar }
                    }
                }
                .ignoresSafeArea(edges: tabletop ? [.bottom] : wide ? [.top, .bottom] : [.top, .leading, .trailing])
                .onGeometryChange(for: Bool.self) { geometry in
                    if #available(iOS 27.1, macOS 27.1, *) {
                        return ShellLayout.divisionAxis(geometry.reservedRegions(kind: .division).first?.frame, in: geometry.size) == .horizontal
                    }
                    return false
                } action: { newValue in
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { tabletop = newValue }
                }
                .overlay(alignment: .topTrailing) {
                    if !nativeBars {
                        HStack(spacing: 10) {
                            ControllerChip(count: controllers, action: openControllers)
                            ShellSettingsChip(action: openShellSettings)
                        }.padding(.top, 6).padding(.trailing, 16)
                    }
                }
                .onChange(of: focus.id) { _, id in
                    guard let id, id.hasPrefix("lib.tile.") || id.hasPrefix("lib.recent.") else { return }
                    if id.hasPrefix("lib.tile.") {
                        scrollToTile(String(id.dropFirst("lib.tile.".count)))
                    } else {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(id.hasSuffix(".play") ? String(id.dropLast(5)) : id, anchor: .center) }
                    }
                }
            }
        }
    }

    private var tabletopHero: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HeroText(status: selected.game.state, title: selected.game.title,
                             explanation: selected.game.state == .playable ? "" : selected.game.state.explanation,
                             titleSize: 40,
                             recentlyPlayed: selected.game.recentlyPlayed ?? "")
                        .modifier(ShellSelectionTransition(value: selected.id))
                        .matchedGeometryEffect(id: "hero.details", in: poseNamespace, properties: .position)
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .bottomLeading)
            }
            .scrollIndicators(.hidden)
        }
        .background { PortraitHeroBackdrop(game: selected.game).ignoresSafeArea(.container, edges: .top) }
    }

    private var expandedHero: some View {
        let height = heroHeight - collapseDistance * collapse
        return heroContent(compact: collapse)
            .padding(.horizontal, 24)
            .padding(.top, topInset)
            .padding(.bottom, 16)
            .frame(height: height)
            .background { PortraitHeroBackdrop(game: selected.game).ignoresSafeArea(.container, edges: .top) }
    }

    private func heroContent(compact: CGFloat) -> some View {
        HeroText(status: selected.game.state, title: selected.game.title,
                 explanation: selected.game.state == .playable ? "" : selected.game.state.explanation,
                 titleSize: 44 - compact * 12,
                 recentlyPlayed: selected.game.recentlyPlayed ?? "")
            .modifier(ShellSelectionTransition(value: selected.id))
            .matchedGeometryEffect(id: "hero.details", in: poseNamespace, properties: .position)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func hero(height: CGFloat, compact: CGFloat, fillsRegion: Bool = false) -> some View {
        HeroView(game: selected.game, width: size.width, topInset: tabletop ? 0 : topInset, height: height,
                 titleSize: wide ? 34 - compact * 6 : short ? 24 : 32, short: short,
                 topSpacing: 60 - compact * 48,
                 coverSide: 96 - compact * 24, fillsRegion: fillsRegion,
                 detailAlignment: expanded ? .bottom : .center, bottomSpacing: expanded ? 16 : 24,
                 pullDown: heroPullDown, poseNamespace: poseNamespace) {}
    }

    private func gameScroll(includesHero: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if includesHero {
                    hero(height: heroHeight, compact: 0)
                    gridHeading
                }
                collection.padding(.top, includesHero ? 12 : short ? 6 : 14)
                recent.padding(.top, 34)
            }.padding(.bottom, 28 + (wide ? bottomInset : 0))
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .background { Color.black.ignoresSafeArea() }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectHidden(tabletop || !expanded, for: .top)
        .accessibilityIdentifier("library.grid")
        .overlay(alignment: .top) {
            if tabletop {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black.opacity(0.75), location: 0.22),
                                       .init(color: .black.opacity(0.25), location: 0.62),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .opacity(gridFade)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onScrollGeometryChange(for: PortraitScrollDecoration.self) {
            PortraitScrollDecoration.value(offset: $0.contentOffset.y + $0.contentInsets.top,
                                           tabletop: tabletop, includesHero: includesHero)
        } action: { _, decoration in
            switch decoration {
            case .fade(let opacity): gridFade = opacity
            case .pullDown(let distance): heroPullDown = distance
            case .inactive: gridFade = 0; heroPullDown = 0
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { oldOffset, offset in
            guard expanded, !tabletop, scrolling, collapseDistance > 0,
                  let expandedScrollInset else { return }
            let travel = offset + expandedScrollInset
            if !heroCollapsed, heroCanCollapse, travel >= 48 {
                heroCollapsed = true
            } else if heroCollapsed, heroExpansionArmed, travel <= 8, offset < oldOffset {
                heroCollapsed = false
                heroExpansionArmed = false
            }
        }
        .onScrollPhaseChange { _, phase, context in
            if !tabletop && phase == .interacting {
                // A new reverse gesture can restore the hero; its own resize cannot retrigger expansion.
                heroExpansionArmed = heroCollapsed
                if expanded, !heroCollapsed {
                    let geometry = context.geometry
                    // Only real scroll range, rather than bounce, may reach the collapse threshold.
                    heroCanCollapse = geometry.contentSize.height + geometry.contentInsets.top
                        + geometry.contentInsets.bottom - geometry.containerSize.height >= 48
                }
                if expandedScrollInset == nil { expandedScrollInset = context.geometry.contentInsets.top }
            }
            scrolling = phase == .interacting || phase == .decelerating
        }
        .onChange(of: size) { _, _ in
            resetHeroGeometry()
        }
        .onChange(of: topInset) { _, _ in resetHeroGeometry() }
        .onChange(of: typeSize) { _, _ in resetHeroGeometry() }
        .onChange(of: tabletop) { _, _ in resetHeroGeometry() }
    }

    private func resetHeroGeometry() {
        expandedScrollInset = nil
        heroCanCollapse = false
        heroCollapsed = false
        heroExpansionArmed = false
    }

    private var gridHeading: some View {
        HStack {
            Text(ShellStrings.text("Your games")).textCase(.uppercase)
                .font(.caption.weight(.semibold)).tracking(1.8)
                .foregroundStyle(.primary)
            Spacer()
            Text("\(games.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)

        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.heading")
        .matchedGeometryEffect(id: "library.heading", in: poseNamespace, properties: .position)
        .background {
            if !tabletop {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.55),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.bottom, -12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if wide {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 22, alignment: .top)],
                          alignment: .leading, spacing: 24) {
                    ForEach(games) { tile($0) }
                }.scrollTargetLayout().padding(.horizontal, 24)
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
                .scrollPosition(id: $rowID, anchor: .center)
                // A game chosen elsewhere (at launch, in Recently played, after a fold) comes into view.
                .onAppear { rowID = selected.id }
                .onChange(of: selected.id) { _, id in
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { rowID = id }
                }
                // A scroll view draws under the safe-area insets, but the covers are sized for the width inside them.
                // Where the system keeps a strip at the side (the iPhone Duo's outer screen, #511) the next card would
                // show there, cut at the screen edge. Clipped to its frame the edge falls between cards again.
                .clipped()
                .padding(.vertical, -6)
            }
        }
    }

    private func scrollToTile(_ id: String) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            if wide { position.scrollTo(id: id, anchor: .center) }
            else { rowID = id }
        }
    }

    private func tile(_ detail: GameDetail) -> some View {
        let chosen = detail.id == selected.id
        let focused = focus.visible && focus.id == "lib.tile.\(detail.id)"
        return Button {
            select(detail.id)
            scrollToTile(detail.id)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                CoverView(game: detail.game, showsState: true)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(ShellPalette.cream, lineWidth: 4)
                            .opacity(chosen || focused ? 1 : 0)
                    }
                    .shellTarget("lib.tile.\(detail.id)", showsRing: false) { primary(detail) }
                Text(detail.game.title).shellType(ShellType.cardTitle).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .foregroundStyle(.white.opacity(chosen ? 1 : 0.86))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detail.game.title + ", " + detail.game.state.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("tile.\(detail.id)")
        .contextMenu {
            Group {
                Button(ShellStrings.text("Play"), systemImage: "play.fill") { primary(detail) }
                    .disabled(detail.game.state != .playable)
                Button(ShellStrings.text("Game settings"), systemImage: "slider.horizontal.3") {
                    select(detail.id); openSettings()
                }
            }
        }

        .accessibilityAction(named: Text(ShellStrings.text("Game settings"))) { select(detail.id); openSettings() }
        .id(detail.id)
    }

    @ViewBuilder private var recent: some View {
        let recent = games.filter { $0.game.recentlyPlayed != nil }
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: ShellStrings.text("Recently played")).padding(.bottom, 8)
                ForEach(recent) { detail in
                    HStack(spacing: 14) {
                        Button { select(detail.id) } label: {
                            HStack(spacing: 14) {
                                CoverThumbnail(game: detail.game, showsShadow: false, cornerRadius: 8)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(detail.game.title).shellText(15, .semibold).multilineTextAlignment(.leading)
                                    GameMetadataSubtitle(state: detail.game.state, recentlyPlayed: detail.game.recentlyPlayed ?? "")
                                }
                                Spacer(minLength: 8)
                            }
                            .frame(maxWidth: .infinity, minHeight: RecentRow.minHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(detail.game.title)
                        .accessibilityIdentifier("recent.select.\(detail.id)")
                        .shellTarget("lib.recent.\(detail.id)") { select(detail.id) }
                        // Keep this glass independent from the persistent primary action's morphing group.
                        GlassEffectContainer {
                            Button { primary(detail) } label: {
                                Image(systemName: "play.fill").frame(minWidth: 24, minHeight: 24)
                            }
                            .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                            .tint(.white).foregroundStyle(.white)
                            .disabled(detail.game.state != .playable)
                            .accessibilityLabel(ShellStrings.text("Play") + ", " + detail.game.title)
                            .accessibilityIdentifier("recent.play.\(detail.id)")
                            .shellTarget("lib.recent.\(detail.id).play") { if detail.game.state == .playable { primary(detail) } }
                        }
                    }
                    .id("lib.recent.\(detail.id)")
                    if detail.id != recent.last?.id {
                        Rectangle().fill(ShellPalette.hairline).frame(height: 1).padding(.leading, 58)
                            .padding(.vertical, RecentRow.separatorGap)
                    }
                }
            }.padding(.horizontal, 24)
        }
    }

    private var bottomBar: some View {
        let actions = GameLaunchActions(game: selected.game, primary: { primary(selected) }, settings: openSettings, expands: true, glassNamespace: actionGlassNamespace)

        return ZStack {
            // Preserve the inset while the sheet owns interaction and accessibility.
            if obscured { actions.hidden() } else { actions }
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
        .ignoresSafeArea(.container, edges: .horizontal)
        .background {
            LinearGradient(stops: [.init(color: ShellPalette.background.opacity(0), location: 0),
                                   .init(color: ShellPalette.background, location: 0.4)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }
}

/// The chosen game's banner filling the whole hero, darkened toward the bottom where the state, the title and what to
/// do next sit. The hero has one height for every game: the words are bottom-aligned, so a short title simply shows
/// more of the banner and a long one covers more of it. Nothing below moves when the selection changes.
struct HeroView<Accessory: View>: View {
    let game: GameTile
    let width: CGFloat
    let topInset: CGFloat
    /// The header's minimum height; large text can request more room.
    let height: CGFloat
    var titleSize: CGFloat = 34
    /// A short screen (the folded foldable): one line of hint.
    var short = false
    var topSpacing: CGFloat = 60
    var coverSide: CGFloat = 96
    var fillsRegion = false
    var detailAlignment: VerticalAlignment = .bottom
    var bottomSpacing: CGFloat = 16
    var pullDown: CGFloat = 0
    let poseNamespace: Namespace.ID
    @ViewBuilder let accessory: () -> Accessory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeroText(status: game.state, title: game.title,
                     explanation: game.state == .playable ? "" : game.state.explanation,
                     titleSize: max(36, titleSize), hintLines: short ? 1 : 2,
                     recentlyPlayed: game.recentlyPlayed ?? "")
                .modifier(ShellSelectionTransition(value: game.id))
                .matchedGeometryEffect(id: "hero.details", in: poseNamespace, properties: .position)
            accessory()
        }
        .padding(.horizontal, 24)
        .padding(.top, topInset + topSpacing)
        .padding(.bottom, bottomSpacing)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: fillsRegion || typeSize.isAccessibilitySize ? .infinity : height, alignment: .bottomLeading)
        .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize && !fillsRegion)
        .background {
            PortraitHeroBackdrop(game: game)
                .visualEffect { [pullDown] effect, geometry in
                    // Stretch upward without changing the hero's layout or its lower fade boundary.
                    effect.scaleEffect(x: 1, y: 1 + pullDown / max(1, geometry.size.height), anchor: .bottom)
                }
                .allowsHitTesting(false)
        }
    }
}

/// The hero's words: the version, title on at most two lines, playable recency or alert state, and an optional hint.
struct HeroText: View {
    let status: GameState
    let title: String
    let explanation: String
    let titleSize: CGFloat
    var hintLines = 2
    var recentlyPlayed = ""
    var centered = false
    var centering: CGFloat?
    var body: some View {
        Group {
            if let centering {
                HeroTextLayout(centering: centering) { content }
            } else {
                VStack(alignment: centered ? .center : .leading, spacing: 10) { content }
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
    }

    @ViewBuilder private var content: some View {
        metadataSubtitle
            .shellText(13, .medium, relativeTo: .footnote)
            .foregroundStyle(.white.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
        Text(title).shellType(ShellType.heroTitle(titleSize))
            .lineLimit(2).truncationMode(.tail)
            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("hero.title")
        if !explanation.isEmpty {
            Text(explanation).shellType(ShellType.body).foregroundStyle(.white.opacity(0.78)).lineLimit(hintLines).padding(.top, 2)
        }
    }
    @ViewBuilder private var metadataSubtitle: some View {
        if status == .playable {
            if !recentlyPlayed.isEmpty { Text(recentlyPlayed) }
        } else {
            AlertStateChip(state: status)
        }
    }

}

private struct HeroTextLayout: Layout {
    var centering: CGFloat
    var animatableData: CGFloat {
        get { centering }
        set { centering = newValue }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.init(width: proposal.width, height: nil)) }
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0,
                      height: sizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, sizes.count - 1)) * 10)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: bounds.width, height: nil))
            subview.place(at: CGPoint(x: bounds.minX + (bounds.width - size.width) / 2 * centering, y: y),
                          anchor: .topLeading, proposal: .init(width: size.width, height: size.height))
            y += size.height + 10
        }
    }
}

private struct PortraitHeroBackdrop: View {
    let game: GameTile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            ArtView(game: game, lettering: false)
                .id(game.id)
                .transition(.opacity)
        }
            .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.35), value: game.id)
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0.3), location: 0),
                                       .init(color: .black.opacity(0.15), location: 0.3),
                                       .init(color: .black.opacity(0.8), location: 0.58),
                                       .init(color: .black, location: 0.95),
                                       .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .ignoresSafeArea(.container, edges: .horizontal)
            .accessibilityHidden(true)
    }
}
