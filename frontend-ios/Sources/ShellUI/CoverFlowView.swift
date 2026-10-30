import SwiftUI

/// The library when it is wider than it is tall: one card in the middle, its neighbours turned back, the title and
/// state underneath. The card is the button: a tap on the centred card does what the game needs (Play, choose its
/// data, how to fix it). The backdrop (the blurred banner) is drawn by the library behind the safe area.
struct CoverFlowView: View, Equatable {
    let games: [GameDetail]
    let selected: GameDetail
    let controllers: Int
    /// The controller hints at the bottom, while a controller or keyboard is in use.
    let showsHints: Bool
    /// The screen's safe areas around this view, so the cards can sit in the middle of the whole screen.
    var screenInsets = EdgeInsets()
    let select: (String) -> Void
    let primary: (GameDetail) -> Void
    let openSettings: () -> Void
    let openControllers: () -> Void
    @State private var centredID: String?
    /// How far the carousel is scrolled: 0 with the first card in the middle.
    @State private var scrolled: CGFloat = 0
    /// True from the first touch of a scroll until it has settled.
    @State private var userScrolling = false
    /// The card nearest the middle when the current touch began, also mid-snap, for one card per gesture.
    @State private var gestureStart = 0
    /// False while the carousel scrolls, decelerates or snaps: a tap on the centre card then does nothing.
    @State private var settled = true
    /// A long press on the centre card opened settings: the touch that ends it must not also play.
    @State private var longPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Re-render only for what is drawn: the games' tiles, the selection and the hints. Settings changes elsewhere do
    /// not reach the carousel.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.games.map(\.game) == rhs.games.map(\.game) && lhs.selected.game == rhs.selected.game
            && lhs.controllers == rhs.controllers && lhs.showsHints == rhs.showsHints && lhs.screenInsets == rhs.screenInsets
    }

    var body: some View {
        GeometryReader { geometry in
            let short = geometry.size.height < 520
            // The centred card sits in the middle of the whole screen, the top bar laid over it. The title and state
            // go under the card at a fixed distance, so the card is only as tall as leaves room for them above the
            // bottom edge, and never so wide that the neighbours vanish.
            let height = geometry.size.height
            let middle = (height + screenInsets.top + screenInsets.bottom) / 2 - screenInsets.top
            let gap: CGFloat = short ? 10 : 24
            let words = Self.infoHeight(short: short)
            let below: CGFloat = short ? 4 : 56          // the hint row on a tablet, a margin on a phone
            let byBottom = 2 * (height - middle - gap - words - below)
            let byTop = 2 * (middle - (short ? 54 : 76))
            let cardHeight = max(90, min(byBottom, byTop, geometry.size.width * 0.54 * 9 / 16) / 1.06)
            let cover = cardHeight * 16 / 9
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Group {
                        if games.count <= 3 { shelf(width: geometry.size.width, cover: cover) } else { carousel(width: geometry.size.width, cover: cover) }
                    }.frame(height: cardHeight * 1.06)
                    info(short: short, width: geometry.size.width)
                        .padding(.top, gap).padding(.horizontal, 24)
                }
                .padding(.top, middle - cardHeight * 1.06 / 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                topBar(short: short).padding(.horizontal, 24).padding(.top, short ? 4 : 16)
                if !short {
                    // The hint row keeps its place when it is hidden, so nothing moves when it appears.
                    hints.opacity(showsHints ? 1 : 0).padding(.bottom, 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selected.id)
        .onAppear { centredID = selected.id }
        .onChange(of: selected.id) { _, id in
            // A selection from the D-pad or a tap scrolls the carousel. Never while the player is touching it or it is
            // still moving: the player's gesture always wins.
            guard centredID != id, !userScrolling else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { centredID = id }
        }
    }

    /// The title and state under the card: two lines of title reserved, then the state line.
    static func infoHeight(short: Bool) -> CGFloat {
        let size: CGFloat = short ? 18 : 28
        return size * 1.3 * 2 + 8 + 34
    }

    private func topBar(short: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            SectionHeading(title: ShellStrings.text("Your games"))
            Text(ShellStrings.text("\(position) of \(games.count)")).shellText(12, .medium, relativeTo: .caption)
                .monospacedDigit().foregroundStyle(.white.opacity(0.45)).padding(.leading, 4)
            Spacer(minLength: 12)
            if short {
                // On a phone on its side the hints share the top bar, so the cards keep the height.
                hints.opacity(showsHints ? 1 : 0)
                Spacer(minLength: 12)
            }
            Button(action: openSettings) { Image(systemName: "slider.horizontal.3").frame(minWidth: 18) }
                .buttonStyle(ChipButtonStyle())
                .accessibilityLabel(ShellStrings.text("Game settings") + ", " + selected.game.title)
                .accessibilityIdentifier("settings.open")
                .shellTarget("lib.settings", radius: 22, action: openSettings)
            ControllerChip(count: controllers, action: openControllers)
        }
    }
    private var position: Int { (games.firstIndex { $0.id == selected.id } ?? 0) + 1 }
    private var selectedIndex: Int { games.firstIndex { $0.id == selected.id } ?? 0 }

    /// More than three games: a carousel that moves one card per gesture, the neighbours turned back a little and
    /// tucked behind the middle card, a deck rather than a row.
    private func carousel(width: CGFloat, cover: CGFloat) -> some View {
        let spacing = cover * 0.04
        let stride = cover + spacing
        let margin = max(0, (width - cover) / 2)
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
        .scrollTargetBehavior(CardSnap(stride: stride, count: games.count, start: gestureStart))
        .scrollPosition(id: $centredID, anchor: .center)
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x + $0.contentInsets.leading } action: { _, offset in
            scrolled = offset
        }
        .onScrollPhaseChange { old, phase, context in
            // A touch scroll goes interacting, decelerating, maybe animating (the snap), then idle. Only once it has
            // settled does the card in the middle become the selection, read from the final offset itself, so a stale
            // value can never send the carousel back. A scroll this view animates starts from idle and never sets the
            // flag, so it never selects.
            settled = phase == .idle
            if phase == .interacting && old != .interacting {
                let offset = context.geometry.contentOffset.x + context.geometry.contentInsets.leading
                gestureStart = min(games.count - 1, max(0, Int((offset / stride).rounded())))
            }
            switch phase {
            case .interacting, .decelerating: userScrolling = true
            case .idle:
                if userScrolling {
                    let offset = context.geometry.contentOffset.x + context.geometry.contentInsets.leading
                    let index = min(games.count - 1, max(0, Int((offset / stride).rounded())))
                    if games[index].id != selected.id { select(games[index].id) }
                }
                userScrolling = false
            default: break
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    /// One to three games: they sit together in the middle, the chosen one in front and larger. No empty track.
    private func shelf(width: CGFloat, cover: CGFloat) -> some View {
        let card = min(cover, width / (1 + CGFloat(games.count - 1) * 0.8))
        let chosenIndex = selectedIndex
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
            // The centred card acts like the game's primary action, once the carousel has settled. A side card only
            // comes to the middle and never starts anything.
            if longPressed { longPressed = false; return }
            if chosen {
                if settled { primary(detail) }
                return
            }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { centredID = detail.id }
            select(detail.id)
        } label: {
            CoverView(game: detail.game, radius: cover * 0.03, showsState: true)
                .frame(width: cover, height: cover * 9 / 16)
                .shadow(color: .black.opacity(0.5), radius: cover * 0.05, y: cover * 0.03)
        }
        .buttonStyle(.plain)
        // A long press on the centred card opens its settings, a shortcut for the button at the top.
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            guard chosen, settled else { return }
            longPressed = true
            openSettings()
        })
        .sensoryFeedback(.impact(weight: .medium), trigger: longPressed) { _, new in new }
        .shellTarget("lib.tile.\(detail.id)", radius: cover * 0.03) { primary(detail) }
        .accessibilityLabel(detail.game.title + ", " + detail.game.state.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityHint(chosen ? detail.game.state.actionTitle : ShellStrings.text("Double-tap to select"))
        .accessibilityIdentifier("tile.\(detail.id)")
    }

    /// Under the centre card, the same on a phone and a tablet: the title with room for two lines, then one line of
    /// state. For a game that cannot start, that line is the way out: a small chip that says what is wrong and what to
    /// do. The space is reserved, so nothing moves when the selection changes, only the words crossfade.
    private func info(short: Bool, width: CGFloat) -> some View {
        let game = selected.game
        let size: CGFloat = short ? 18 : 28
        return ZStack(alignment: .top) {
            VStack(spacing: 8) {
                Text("M\nM").shellType(ShellType.flowTitle(size))
                StateChip(game: game) {}.allowsHitTesting(false)
            }.hidden().accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(game.title).shellType(ShellType.flowTitle(size))
                    .lineLimit(2).truncationMode(.tail).multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.35), radius: 10)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("hero.title")
                // A ready game needs no words: its green dot says it. A game that cannot start gets one small line, its
                // way out in the state's colour. The space is reserved either way.
                if game.state == .playable {
                    Color.clear.frame(height: 34).accessibilityHidden(true)
                } else {
                    StateAction(game: game) { primary(selected) }
                }
            }
            .id(game.id).transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: game.id)
        .frame(maxWidth: min(560, width - 48))
        .dynamicTypeSize(...(short ? DynamicTypeSize.xxLarge : DynamicTypeSize.accessibility1))
    }

    private var hints: some View {
        HStack(spacing: 24) {
            GlyphHint(role: .activate, label: selected.game.state.actionTitle)
            GlyphHint(role: .settings, label: ShellStrings.text("Game settings"))
            GlyphHint(role: .controllers, label: ShellStrings.text("Controllers"))
        }
        .frame(minHeight: 24)
        .accessibilityHidden(true)
    }
}

/// The way out for a game that cannot start, as one small tappable line in the state's colour: "How to fix ›".
/// VoiceOver reads the state with it.
struct StateAction: View {
    let game: GameTile
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(game.state.actionTitle).shellType(ShellType.button)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(game.state.color)
            .lineLimit(1)
            .padding(.horizontal, 12).frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(game.state.title + ", " + game.state.actionTitle)
        .accessibilityIdentifier("state.chip")
        .shellTarget("lib.chip", radius: 17, action: action)
    }
}

/// What is wrong and what to do, as one small tappable line: "Game files damaged · How to fix".
struct StateChip: View {
    let game: GameTile
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(game.state.color).frame(width: 7, height: 7)
                Text(game.state.title.uppercased()).shellType(ShellType.eyebrow)
                    .foregroundStyle(game.state.color)
                Text("·").foregroundStyle(.white.opacity(0.4))
                Text(game.state.chipAction).shellType(ShellType.button)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).opacity(0.6)
            }
            .lineLimit(1)
            .padding(.horizontal, 14).frame(minHeight: 34)
            .background(.black.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            .contentShape(Capsule().inset(by: -6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(game.state.title + ", " + game.state.actionTitle)
        .accessibilityIdentifier("state.chip")
        .shellTarget("lib.chip", radius: 17, action: action)
    }
}

/// Moves the carousel one card per gesture, like paging: a flick goes to the neighbour of the card the touch began on,
/// a slow drag settles on the card nearest the middle. The target is always a card close by, so the snap is short
/// instead of a long glide, and a second swipe that starts mid-snap counts from where the carousel is.
struct CardSnap: ScrollTargetBehavior {
    let stride: CGFloat
    let count: Int
    /// The card nearest the middle when the touch began.
    let start: Int
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let card = Self.card(target: target.rect.origin.x, velocity: context.velocity.dx, stride: stride, count: count, start: start)
        target.rect.origin.x = CGFloat(card) * stride
    }
    /// The card a gesture ends on. `target` is where the scroll would rest, in content points (0 with the first card in
    /// the middle), `velocity` the release speed in points per millisecond, positive toward the later cards.
    static func card(target: CGFloat, velocity: CGFloat, stride: CGFloat, count: Int, start: Int) -> Int {
        let nearest = Int((target / stride).rounded())
        let card: Int
        if velocity > flickVelocity { card = max(start + 1, min(nearest, start + 1)) }
        else if velocity < -flickVelocity { card = min(start - 1, max(nearest, start - 1)) }
        else { card = nearest }
        return min(count - 1, max(0, card))
    }
    /// Above this release speed (points per millisecond) the gesture counts as a flick.
    static let flickVelocity: CGFloat = 0.3
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
