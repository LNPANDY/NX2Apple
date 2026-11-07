import SwiftUI

/// The library when it is wider than it is tall: one card in the middle, its neighbours turned back, the title and
/// state underneath. The card is the button: a tap on the centred card does what the game needs (Play, choose its
/// data, how to fix it). The backdrop (the blurred banner) is drawn by the library behind the safe area.
struct CoverFlowView: View, Equatable {
    @Environment(\.shellNativeBars) private var nativeBars
    let games: [GameDetail]
    let selected: GameDetail
    let controllers: Int
    /// The controller hints at the bottom, while a controller or keyboard is in use.
    let showsHints: Bool
    var obscured = false
    /// The screen's safe areas around this view, so the cards can sit in the middle of the whole screen.
    var screenInsets = EdgeInsets()
    let select: (String) -> Void
    let primary: (GameDetail) -> Void
    let openSettings: () -> Void
    let openControllers: () -> Void
    let openShellSettings: () -> Void
    @State private var centredID: String?
    @State private var division: CGRect?
    private var divided: Bool { division != nil }
    /// How far the carousel is scrolled: 0 with the first card in the middle.
    @State private var scrolled: CGFloat = 0
    /// True from the first touch of a scroll until it has settled.
    @State private var userScrolling = false
    /// False while the carousel scrolls, decelerates or snaps: a tap on the centre card then does nothing.
    @State private var settled = true
    /// A long press on the centre card opened settings: the touch that ends it must not also play.
    @State private var longPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Re-render only for what is drawn: the games' tiles, the selection and the hints. Settings changes elsewhere do
    /// not reach the carousel.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.games.map(\.game) == rhs.games.map(\.game) && lhs.selected.game == rhs.selected.game
            && lhs.controllers == rhs.controllers && lhs.showsHints == rhs.showsHints && lhs.screenInsets == rhs.screenInsets && lhs.obscured == rhs.obscured
    }

    var body: some View {
        GeometryReader { geometry in
            flow(size: geometry.size)
                .onGeometryChange(for: CGRect?.self) { proxy in
                    if #available(iOS 27.1, macOS 27.1, *) {
                        let region = proxy.reservedRegions(kind: .division).first?.frame
                        return ShellLayout.divisionAxis(region, in: proxy.size) == .vertical ? region : nil
                    }
                    return nil
                } action: { division = $0 }
        }
        .ignoresSafeArea(.container)
        .sensoryFeedback(.selection, trigger: selected.id)
        .onAppear { centredID = selected.id }
        .onChange(of: selected.id) { _, id in

            // A selection from the D-pad or a tap scrolls the carousel. Never while the player is touching it or it is
            // still moving: the player's gesture always wins.
            guard centredID != id, !userScrolling else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { centredID = id }
        }
    }

    @ViewBuilder private func flow(size: CGSize) -> some View {
        let short = size.height < 520
        // Keep the focused card in the leading usable region when a division is active.
        let height = size.height
        let primaryWidth = division?.minX ?? size.width
        let gap: CGFloat = short ? 10 : 24
        let words = Self.infoHeight(short: short)
        let footer: CGFloat = short ? 36 : 56
        let bar = nativeBars ? 0 : Self.barTop(short: short) + Self.barHeight
        // Use the same usable half-width in both inner-display poses; folding only changes the anchor.
        let artworkWidth = short ? size.width * 0.64 : max(0, size.width / 2 - 48)
        let cardHeight = max(90, min(artworkWidth * 9 / 16, height - words - gap - footer - bar - 32) / 1.06)
        let cover = cardHeight * 16 / 9
        ZStack(alignment: .top) {
            VStack(spacing: gap) {
                carousel(width: size.width, cover: cover, primaryWidth: primaryWidth)
                    .frame(height: cardHeight * 1.06)
                info(short: short, width: primaryWidth)
                    .frame(width: size.width, alignment: divided ? .leading : .center)
            }
            .overlay(alignment: .bottom) {
                launchActions(width: primaryWidth)
                    .frame(width: size.width, alignment: divided ? .leading : .center)
                    .alignmentGuide(.bottom) { $0[.top] - gap }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            if !nativeBars { topBar(short: short).padding(.horizontal, 24).padding(.top, Self.barTop(short: short)) }
        }
        .overlay(alignment: .bottom) {
            // Hints stay outside the centered cover row without shifting its midpoint.
            if nativeBars || divided || !short {
                hints
                    .opacity(showsHints ? 1 : 0)
                    .frame(width: divided ? max(0, primaryWidth - 48) : max(0, size.width - 48))
                    .padding(.horizontal, 24)
                    .padding(.vertical, short ? 4 : 12)
                    .frame(maxWidth: .infinity, alignment: divided ? .leading : .center)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The title and state under the card: two lines of title reserved, then the state line.
    static func infoHeight(short: Bool) -> CGFloat {
        let size: CGFloat = short ? 18 : 28
        return size * 1.3 * 2 + (short ? 52 : 72) + 58
    }

    /// The distance from the top of the safe area to the top bar. A phone on its side has no status bar, so the chips
    /// need their own air above them there. The bar is one centred row, so the title and the chips share a centre.
    static func barTop(short: Bool) -> CGFloat { short ? 12 : 16 }
    static let barHeight: CGFloat = 44

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
            if !nativeBars {
                ControllerChip(count: controllers, action: openControllers)
                ShellSettingsChip(action: openShellSettings)
            }
        }
        // On a phone on its side the hints share the row. At the largest sizes they would wrap into a tall block and the
        // title and chips, centred in it, would sink away from the top edge, so the row stops growing at xxLarge, as the
        // title under the card does.
        .dynamicTypeSize(...(short ? DynamicTypeSize.xxLarge : DynamicTypeSize.accessibility5))
    }
    private var position: Int { (games.firstIndex { $0.id == selected.id } ?? 0) + 1 }

    /// One native snapping carousel, with the neighbours turned back a little and
    /// tucked behind the middle card, a deck rather than a row.
    private func carousel(width: CGFloat, cover: CGFloat, primaryWidth: CGFloat) -> some View {
        let spacing = cover * 0.04
        let stride = cover + spacing
        let margin = max(0, (primaryWidth - cover) / 2)
        let anchor: UnitPoint = divided ? .leading : .center
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
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne, anchor: anchor))
        .scrollPosition(id: $centredID, anchor: anchor)
        .contentMargins(.leading, margin, for: .scrollContent)
        .contentMargins(.trailing, max(0, width - cover - margin), for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x + $0.contentInsets.leading } action: { _, offset in
            scrolled = offset
            guard !games.isEmpty else { return }
            let index = min(games.count - 1, max(0, Int((offset / stride).rounded())))
            if userScrolling, games[index].id != selected.id { select(games[index].id) }
        }
        .onScrollPhaseChange { _, phase, context in
            // Preview the nearest card while dragging; commit the final scroll ID only when snapping settles.
            settled = phase == .idle
            switch phase {
            case .interacting, .decelerating: userScrolling = true
            case .idle:
                if userScrolling, !games.isEmpty {
                    let offset = context.geometry.contentOffset.x + context.geometry.contentInsets.leading
                    let index = min(games.count - 1, max(0, Int((offset / stride).rounded())))
                    if games[index].id != selected.id { select(games[index].id) }
                    centredID = games[index].id
                }
                userScrolling = false
            default: break
            }
        }
        .accessibilityIdentifier("library.coverflow")
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
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
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { centredID = detail.id }
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
        .accessibilityLabel([detail.game.title, detail.game.state.title, detail.game.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityHint(chosen ? detail.game.state.actionTitle : ShellStrings.text("Double-tap to select"))
        .accessibilityIdentifier("tile.\(detail.id)")
        .accessibilityAction(named: Text(ShellStrings.text("Game settings"))) { select(detail.id); openSettings() }
    }

    /// Under the centre card, the same on a phone and a tablet: the title with room for two lines, then one line of
    /// state. For a game that cannot start, that line is the way out: a small chip that says what is wrong and what to
    /// do. The space is reserved, so nothing moves when the selection changes, only the words crossfade.
    @ViewBuilder private func info(short: Bool, width: CGFloat) -> some View {
        let game = selected.game
        let size: CGFloat = short ? 18 : 28
        VStack(alignment: divided ? .leading : .center, spacing: short ? 16 : 24) {
            ZStack(alignment: divided ? .leading : .center) {
                VStack(alignment: divided ? .leading : .center, spacing: short ? 6 : 10) {
                    if game.state.artworkWarning == nil {
                        StatusLabel(state: game.state, prominent: true)
                    }
                    Text(game.title).shellType(ShellType.flowTitle(size))
                        .lineLimit(2).truncationMode(.tail)
                        .multilineTextAlignment(divided ? .leading : .center)
                        .shadow(color: .black.opacity(0.35), radius: 10)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("hero.title")
                    if game.state != .playable, !game.state.explanation.isEmpty {
                        Text(game.state.explanation).shellType(ShellType.body)
                            .foregroundStyle(.white.opacity(0.78)).lineLimit(2)
                            .multilineTextAlignment(divided ? .leading : .center)
                    }
                }
                .modifier(ShellSelectionTransition(value: game.id, duration: 0.16))
            }

        }
        .frame(maxWidth: max(0, min(560, width - 48)), alignment: divided ? .leading : .center)
        .padding(.horizontal, 24)
        .dynamicTypeSize(...(short ? DynamicTypeSize.xxLarge : DynamicTypeSize.accessibility1))
    }

    private func launchActions(width: CGFloat) -> some View {
        let game = selected.game
        return ZStack(alignment: divided ? .leading : .center) {
                let actions = GameLaunchActions(game: game, primary: { primary(selected) }, settings: openSettings,
                                                alignment: divided ? .leading : .center, transitionDuration: 0.18)
                if obscured { actions.hidden() } else { actions }
            }
            .frame(maxWidth: max(0, min(560, width - 48)))
            .padding(.horizontal, 24)
    }

    private var hints: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { hintItems }
            VStack(alignment: .leading, spacing: 6) { hintItems }
        }
        .frame(minHeight: 24)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var hintItems: some View {
        GlyphHint(role: .activate, label: selected.game.state.actionTitle)
        GlyphHint(role: .settings, label: ShellStrings.text("Game settings"))
        GlyphHint(role: .controllers, label: ShellStrings.text("Controllers"))
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
        .animation(reduceMotion ? .linear(duration: 0.12) : .easeInOut(duration: 0.22).delay(0.04), value: game.id)
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

/// The gear at the top-right corner, which opens the shell's own settings.
struct ShellSettingsChip: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape").frame(minWidth: 18)
        }
            .buttonStyle(ChipButtonStyle())
            .accessibilityLabel(ShellStrings.text("Settings"))
            .accessibilityIdentifier("shellSettings.open")
            .shellTarget("lib.shellSettings", radius: 22, action: action)
    }
}
