import SwiftUI

/// The library when it is wider than it is tall: one cover in the middle, its neighbours turned back, the title,
/// state and primary action underneath. The backdrop (the blurred cover) is drawn by the library behind the safe area.
struct CoverFlowView: View {
    let games: [GameDetail]
    let selected: GameDetail
    let controllers: Int
    let showsHints: Bool
    let select: (String) -> Void
    let primary: (GameDetail) -> Void
    let openSettings: () -> Void
    let openControllers: () -> Void
    @State private var centredID: String?
    /// How far the carousel is scrolled: 0 with the first cover in the middle.
    @State private var scrolled: CGFloat = 0
    @State private var userScrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geometry in
            let short = geometry.size.height < 520
            // A wide card as large as the Mac console's focused tile: what the height allows, never so wide that the
            // neighbours vanish.
            let cardHeight = max(90, min(geometry.size.height * (short ? 0.5 : 0.42), geometry.size.width * 0.52 * 9 / 16))
            let cover = cardHeight * 16 / 9
            VStack(spacing: 0) {
                topBar.padding(.horizontal, 24).padding(.top, short ? 4 : 16)
                Spacer(minLength: short ? 4 : 12)
                Group {
                    if games.count <= 3 { shelf(width: geometry.size.width, cover: cover) } else { carousel(width: geometry.size.width, cover: cover) }
                }.frame(height: cover * 9 / 16 * 1.06)
                info(short: short, width: geometry.size.width)
                    .padding(.top, short ? 14 : 28).padding(.horizontal, 24)
                Spacer(minLength: short ? 4 : 12)
                if showsHints && !short {
                    hints.padding(.bottom, 20)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selected.id)
        .onAppear { centredID = selected.id }
        .onChange(of: centredID) { _, id in
            // Only a scroll the player makes chooses a game. A scroll this view animates (after the D-pad or a tap)
            // passes other covers on the way and must not choose them.
            if userScrolling, let id, id != selected.id { select(id) }
        }
        .onChange(of: selected.id) { _, id in
            guard centredID != id else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) { centredID = id }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            SectionHeading(title: ShellStrings.text("Your games"))
            Text(ShellStrings.text("\(position) of \(games.count)")).shellText(12, .medium, relativeTo: .caption)
                .monospacedDigit().foregroundStyle(.white.opacity(0.45)).padding(.leading, 6)
            Spacer(minLength: 12)
            ControllerChip(count: controllers, action: openControllers)
        }
    }
    private var position: Int { (games.firstIndex { $0.id == selected.id } ?? 0) + 1 }

    /// More than three games: a snapping carousel. The neighbours turn back a little and tuck behind the middle card,
    /// a deck rather than a row, which suits wide banners better than the steep turn of square covers.
    private func carousel(width: CGFloat, cover: CGFloat) -> some View {
        let spacing = cover * 0.04
        let stride = cover + spacing
        return ScrollView(.horizontal) {
            LazyHStack(spacing: spacing) {
                ForEach(Array(games.enumerated()), id: \.element.id) { index, detail in
                    // Places from the middle: -1 is the neighbour on the left, 1 the one on the right.
                    coverButton(detail, cover: cover)
                        .modifier(FlowTilt(place: CGFloat(index) - scrolled / stride, cover: cover, flat: reduceMotion))
                        .id(detail.id)
                }
            }.scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centredID, anchor: .center)
        .contentMargins(.horizontal, max(0, (width - cover) / 2), for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x + $0.contentInsets.leading } action: { _, offset in
            scrolled = offset
        }
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .interacting, .decelerating: userScrolling = true
            case .idle:
                if userScrolling, let id = centredID, id != selected.id { select(id) }
                userScrolling = false
            default: userScrolling = false
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    /// One to three games: they sit together in the middle, the chosen one in front and larger. No empty track.
    private func shelf(width: CGFloat, cover: CGFloat) -> some View {
        let card = min(cover, width / (1 + CGFloat(games.count - 1) * 0.8))
        let chosenIndex = games.firstIndex { $0.id == selected.id } ?? 0
        return ZStack {
            ForEach(Array(games.enumerated()), id: \.element.id) { index, detail in
                let chosen = index == chosenIndex
                coverButton(detail, cover: card)
                    .scaleEffect(chosen ? 1 : 0.8)
                    .brightness(chosen ? 0 : -0.22)
                    .offset(x: (CGFloat(index) - CGFloat(games.count - 1) / 2) * card * 0.78)
                    .zIndex(chosen ? 10 : -Double(abs(index - chosenIndex)))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: selected.id)
        .frame(maxWidth: .infinity)
    }

    private func coverButton(_ detail: GameDetail, cover: CGFloat) -> some View {
        let chosen = detail.id == selected.id
        return Button {
            if chosen { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) { centredID = detail.id }
            select(detail.id)
        } label: {
            CoverView(game: detail.game, radius: cover * 0.03)
                .frame(width: cover, height: cover * 9 / 16)
                .shadow(color: .black.opacity(0.5), radius: cover * 0.05, y: cover * 0.03)
        }
        .buttonStyle(.plain)
        .shellTarget("lib.tile.\(detail.id)", radius: cover * 0.03) { primary(detail) }
        .accessibilityLabel(detail.game.title + ", " + detail.game.state.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("tile.\(detail.id)")
    }

    @ViewBuilder private func info(short: Bool, width: CGFloat) -> some View {
        let game = selected.game
        if short {
            // A phone on its side: one line of title and state beside the buttons, so the cover keeps the height.
            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 5) {
                    title(game, size: 20).lineLimit(2).minimumScaleFactor(0.85)
                    StatusLabel(state: game.state)
                }.frame(maxWidth: min(340, width * 0.4), alignment: .leading).fixedSize(horizontal: true, vertical: true)
                actions(game)
            }
            .frame(maxWidth: .infinity)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        } else {
            VStack(spacing: 12) {
                title(game, size: 30).lineLimit(2).multilineTextAlignment(.center)
                StatusLabel(state: game.state, prominent: true)
                if !game.state.explanation.isEmpty {
                    Text(game.state.explanation).shellText(14).foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center).frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true)
                }
                actions(game).padding(.top, 6)
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }

    private func title(_ game: GameTile, size: CGFloat) -> some View {
        Text(game.title).shellText(size, .heavy, relativeTo: .title).tracking(-size * 0.025)
            .shadow(color: .black.opacity(0.35), radius: 10)
            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("hero.title")
            .id("title.\(game.id)").transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: game.id)
    }

    private func actions(_ game: GameTile) -> some View {
        HStack(spacing: 12) {
            Button { primary(selected) } label: { Label(game.state.actionTitle, systemImage: game.state.actionSymbol) }
                .buttonStyle(PrimaryPillStyle())
                .accessibilityLabel(game.state.actionTitle + ", " + game.title)
                .accessibilityIdentifier("state.action")
                .shellTarget("lib.play", radius: 25) { primary(selected) }
            Button(action: openSettings) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(RoundIconButtonStyle())
                .accessibilityLabel(ShellStrings.text("Game settings"))
                .accessibilityIdentifier("settings.open")
                .shellTarget("lib.settings", radius: 25, action: openSettings)
        }
    }

    private var hints: some View {
        HStack(spacing: 24) {
            GlyphHint(letter: "A", label: selected.game.state.actionTitle)
            GlyphHint(letter: "X", label: ShellStrings.text("Game settings"))
            GlyphHint(letter: "Y", label: ShellStrings.text("Controllers"))
        }.accessibilityHidden(true)
    }
}

/// A card's turn by its place: up to 24 degrees back, smaller and darker, pulled in behind its nearer neighbour.
/// The nearer card is always drawn on top. Reduced motion keeps them flat.
private struct FlowTilt: ViewModifier {
    let place: CGFloat
    let cover: CGFloat
    let flat: Bool
    func body(content: Content) -> some View {
        let near = max(-1, min(1, place))
        let far = place > 1 ? place - 1 : place < -1 ? place + 1 : 0
        content
            .rotation3DEffect(.degrees(flat ? 0 : -near * 24), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            .scaleEffect(1 - abs(near) * 0.22)
            .offset(x: -near * cover * 0.28 - far * cover * 0.55)
            .brightness(-abs(near) * 0.25 - min(abs(far), 1) * 0.1)
            .zIndex(-Double(abs(place)))
    }
}

/// The blurred cover behind Cover Flow. It crossfades as the middle cover changes.
struct CoverFlowBackdrop: View {
    let game: GameTile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            ShellPalette.background
            ArtView(game: game, backdrop: true)
                .scaleEffect(1.3)
                .blur(radius: 60, opaque: true)
                .saturation(1.25)
                .opacity(0.75)
                .id(game.id)
                .transition(.opacity)
            // Darker toward the edges and the bottom, so the type and the covers keep their contrast.
            RadialGradient(colors: [.clear, ShellPalette.background.opacity(0.75)], center: .init(x: 0.5, y: 0.4),
                           startRadius: 80, endRadius: 900)
            LinearGradient(colors: [.black.opacity(0.25), .clear, ShellPalette.background.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(reduceMotion ? .linear(duration: 0.2) : .easeInOut(duration: 0.45), value: game.id)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The controller count on top of art, which opens Controllers.
struct ControllerChip: View {
    let count: Int
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: count == 0 ? "gamecontroller" : "gamecontroller.fill")
                Text("\(count)").monospacedDigit()
            }
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityLabel(ShellStrings.text("Controllers") + ", \(count)")
        .accessibilityIdentifier("controllers.open")
        .shellTarget("lib.controllers", radius: 22, action: action)
    }
}
