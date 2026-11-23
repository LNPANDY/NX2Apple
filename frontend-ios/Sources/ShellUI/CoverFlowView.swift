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
    var openHomeScreen: ((String) -> Void)? = nil
    var openCoverPicker: ((String) -> Void)? = nil
    var resetCover: ((String) -> Void)? = nil
    @State private var scrollPosition = ScrollPosition()
    @State private var division: CGRect?
    private var divided: Bool { division != nil }
    private var anchor: UnitPoint { divided ? .leading : .center }
    /// True from the first touch of a scroll until it has settled.
    @State private var userScrolling = false
    /// False while the carousel scrolls, decelerates or snaps: a tap on the centre card then does nothing.
    @State private var settled = true
    /// Monotonic token invalidated on every scroll transition so deferred preview commits drop stale work.
    @State private var previewGeneration: UInt64 = 0
    /// Tracks selection IDs already driven by the scroll view so `onChange(of: selected.id)` does not scroll back.
    @State private var scrollDrivenSelectionID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        .ignoresSafeArea(.container, edges: .horizontal)
        .sensoryFeedback(.selection, trigger: selected.id)
        .onChange(of: selected.id) { _, id in
            if scrollDrivenSelectionID == id {
                scrollDrivenSelectionID = nil
                return
            }
            scrollDrivenSelectionID = nil
            // A selection from the D-pad or a tap scrolls the carousel. Never while the player is touching it or it is
            // still moving: the player's gesture always wins.
            guard !userScrolling else { return }
            previewGeneration &+= 1
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
                scrollPosition.scrollTo(id: id, anchor: anchor)
            }
        }
        .onChange(of: divided) { _, _ in
            guard !userScrolling else { return }
            scrollPosition.scrollTo(id: selected.id, anchor: anchor)
        }
    }

    @ViewBuilder private func flow(size: CGSize) -> some View {
        let safeWidth = max(0, size.width.isFinite ? size.width : 0)
        let safeHeight = max(0, size.height.isFinite ? size.height : 0)
        let short = safeHeight < 520
        // Keep the focused card in the leading usable region when a division is active.
        let primaryWidth = max(0, division?.minX ?? safeWidth)
        let gap: CGFloat = short ? 8 : 20
        let showsBottomHints = nativeBars || divided || !short
        let gameState = selected.game.state
        let hasStatusLabel = gameState != .playable && gameState.artworkWarning == nil
        let hasExplanation = gameState != .playable && !gameState.explanation.isEmpty
        let cardHeight = Self.cardHeight(
            in: CGSize(width: safeWidth, height: safeHeight),
            short: short,
            nativeBars: nativeBars,
            showsBottomHints: showsBottomHints,
            hasStatusLabel: hasStatusLabel,
            hasExplanation: hasExplanation,
            dynamicTypeSize: dynamicTypeSize
        )
        let cover = cardHeight * 16 / 9
        VStack(spacing: 0) {
            if !nativeBars {
                topBar(short: short)
                    .padding(.leading, max(24, screenInsets.leading))
                    .padding(.trailing, max(24, screenInsets.trailing))
                    .padding(.top, Self.barTop(short: short))
            }
            Spacer(minLength: short ? 2 : 12)
            VStack(spacing: gap) {
                carousel(width: safeWidth, cover: cover, primaryWidth: primaryWidth)
                    .frame(height: cardHeight * 1.06)
                info(short: short, width: primaryWidth)
                    .frame(width: safeWidth, alignment: divided ? .leading : .center)
                launchActions(width: primaryWidth)
                    .frame(width: safeWidth, alignment: divided ? .leading : .center)
            }
            Spacer(minLength: short ? 2 : 12)
            if showsBottomHints {
                hints
                    .opacity(showsHints ? 1 : 0)
                    .frame(width: divided ? max(0, primaryWidth - 48) : max(0, safeWidth - max(24, screenInsets.leading) - max(24, screenInsets.trailing)))
                    .padding(.leading, max(24, screenInsets.leading))
                    .padding(.trailing, max(24, screenInsets.trailing))
                    .padding(.vertical, short ? 2 : 10)
                    .frame(maxWidth: .infinity, alignment: divided ? .leading : .center)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: safeWidth, height: safeHeight, alignment: .top)
    }

    /// Computes card height inside the safe-area viewport after reserving space for top bar, title/status/explanation,
    /// inline launch actions, and optional bottom controller hints so nothing overflows on short landscape screens.
    nonisolated static func cardHeight(
        in size: CGSize,
        short: Bool,
        nativeBars: Bool,
        showsBottomHints: Bool,
        hasStatusLabel: Bool = false,
        hasExplanation: Bool = false,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> CGFloat {
        let safeWidth = max(0, size.width.isFinite ? size.width : 0)
        let safeHeight = max(0, size.height.isFinite ? size.height : 0)
        let gap: CGFloat = short ? 8 : 20
        let bar = nativeBars ? 0 : Self.barTop(short: short) + Self.barHeight
        let infoBlock = Self.infoHeight(
            short: short,
            hasStatusLabel: hasStatusLabel,
            hasExplanation: hasExplanation,
            dynamicTypeSize: dynamicTypeSize
        )
        let actionsHeight: CGFloat = 50
        let hintsHeight: CGFloat = showsBottomHints ? (short ? 28 : 44) : 0
        let verticalBreathing: CGFloat = short ? 8 : 24
        let artworkWidth = short ? safeWidth * 0.64 : max(0, safeWidth / 2 - 48)
        let availableForCarousel = max(0, safeHeight - bar - infoBlock - actionsHeight - gap * 2 - hintsHeight - verticalBreathing)
        return max(0, min(artworkWidth * 9 / 16, availableForCarousel / 1.06))
    }

    /// Approximate typography growth factor clamped to the info block's max Dynamic Type size.
    nonisolated static func infoTypeScale(for dynamicTypeSize: DynamicTypeSize, short: Bool) -> CGFloat {
        switch dynamicTypeSize {
        case .xSmall, .small, .medium, .large:
            return 1.0
        case .xLarge:
            return 1.12
        case .xxLarge:
            return 1.24
        default:
            return short ? 1.24 : 1.36
        }
    }

    /// The title and state under the card: two lines of title plus optional status eyebrow and explanation.
    nonisolated static func infoHeight(
        short: Bool,
        hasStatusLabel: Bool = false,
        hasExplanation: Bool = false,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> CGFloat {
        let size: CGFloat = short ? 18 : 28
        let scale = Self.infoTypeScale(for: dynamicTypeSize, short: short)
        let titleHeight = size * 1.3 * 2 * scale
        let statusHeight: CGFloat = hasStatusLabel ? (short ? 24 : 30) * scale : 0
        let explanationHeight: CGFloat = hasExplanation ? (short ? 46 : 56) * scale : 0
        let basePadding: CGFloat = short ? 8 : 16
        return titleHeight + statusHeight + explanationHeight + basePadding
    }

    /// The distance from the top of the safe area to the top bar. A phone on its side has no status bar, so the chips
    /// need their own air above them there. The bar is one centred row, so the title and the chips share a centre.
    nonisolated static func barTop(short: Bool) -> CGFloat { short ? 12 : 16 }
    nonisolated static let barHeight: CGFloat = 44

    private func topBar(short: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            SectionHeading(title: ShellStrings.text("Your games"))
            Text(ShellStrings.text("\(position) of \(games.count)")).shellText(12, .medium, relativeTo: .caption)
                .monospacedDigit().foregroundStyle(.white.opacity(0.62)).padding(.leading, 4)
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
    private var selectedIndex: Int { games.firstIndex { $0.id == selected.id } ?? 0 }
    private var position: Int { selectedIndex + 1 }

    struct CarouselMetrics: Equatable, Sendable {
        let stride: CGFloat
        let leadingMargin: CGFloat
        let trailingMargin: CGFloat
        let targetMidX: CGFloat
    }

    nonisolated static func carouselMetrics(width: CGFloat, cover: CGFloat, primaryWidth: CGFloat) -> CarouselMetrics {
        let stride = cover * 0.64
        let leadingMargin = max(0, (primaryWidth - stride) / 2)
        let trailingMargin = max(0, width - stride - leadingMargin)
        // `.scrollView(axis: .horizontal)` is already inset by `.contentMargins(.leading, leadingMargin, for: .scrollContent)`,
        // so the centred card's midpoint in that coordinate space is `stride / 2`.
        return CarouselMetrics(stride: stride, leadingMargin: leadingMargin,
                               trailingMargin: trailingMargin, targetMidX: stride / 2)
    }

    nonisolated static func cardPlace(midX: CGFloat, targetMidX: CGFloat, stride: CGFloat) -> CGFloat {
        guard stride > 0, midX.isFinite, targetMidX.isFinite else { return 0 }
        return (midX - targetMidX) / stride
    }

    /// Nearest card index for a horizontal content offset along the fixed-stride carousel.
    nonisolated static func nearestIndex(offset: CGFloat, stride: CGFloat, count: Int) -> Int {
        guard count > 0, stride > 0, offset.isFinite else { return 0 }
        return min(count - 1, max(0, Int((offset / stride).rounded())))
    }

    private func scheduleScrollSelection(index: Int, requireUserScrolling: Bool) {
        guard games.indices.contains(index) else { return }
        let targetID = games[index].id
        guard targetID != selected.id else { return }
        previewGeneration &+= 1
        let generation = previewGeneration
        Task { @MainActor in
            guard previewGeneration == generation else { return }
            guard requireUserScrolling ? userScrolling : !userScrolling else { return }
            guard games.indices.contains(index), games[index].id == targetID, selected.id != targetID else { return }
            scrollDrivenSelectionID = targetID
            select(targetID)
        }
    }

    /// One native snapping carousel, with the neighbours turned back a little and
    /// tucked behind the middle card, a deck rather than a row.
    private func carousel(width: CGFloat, cover: CGFloat, primaryWidth: CGFloat) -> some View {
        let metrics = Self.carouselMetrics(width: width, cover: cover, primaryWidth: primaryWidth)
        let stride = metrics.stride
        let targetMidX = metrics.targetMidX
        let anchor = self.anchor
        let currentIndex = selectedIndex
        return ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(games.enumerated()), id: \.element.id) { index, detail in
                    // Places from the middle: -1 is the neighbour on the left, 1 the one on the right.
                    coverButton(detail, cover: cover)
                        .visualEffect { [flat = reduceMotion, stride, targetMidX] content, proxy in
                            let place = Self.cardPlace(midX: proxy.frame(in: .scrollView(axis: .horizontal)).midX,
                                                       targetMidX: targetMidX, stride: stride)
                            let near = max(-1, min(1, place))
                            let far = place > 1 ? place - 1 : place < -1 ? place + 1 : 0
                            return content
                                .rotation3DEffect(.degrees(flat ? 0 : -near * 24), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                                .scaleEffect(1 - abs(near) * 0.22)
                                .brightness(-abs(near) * 0.25 - min(abs(far), 1) * 0.1)
                        }
                        .frame(width: stride, height: cover * 9 / 16)
                        .zIndex(-Double(abs(index - currentIndex)))
                        .id(detail.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne, anchor: anchor))
        .scrollPosition($scrollPosition, anchor: anchor)
        .contentMargins(.leading, metrics.leadingMargin, for: .scrollContent)
        .contentMargins(.trailing, metrics.trailingMargin, for: .scrollContent)
        .onAppear {
            scrollPosition.scrollTo(id: selected.id, anchor: anchor)
        }
        .onChange(of: metrics) { _, _ in
            guard !userScrolling else { return }
            scrollPosition.scrollTo(id: selected.id, anchor: anchor)
        }
        .onScrollGeometryChange(for: Int.self) { geometry in
            Self.nearestIndex(offset: geometry.contentOffset.x + geometry.contentInsets.leading,
                              stride: stride, count: games.count)
        } action: { _, index in
            guard userScrolling, games.indices.contains(index) else { return }
            scheduleScrollSelection(index: index, requireUserScrolling: true)
        }
        .onScrollPhaseChange { _, phase, context in
            // Preview the nearest card while dragging and commit the final selection asynchronously when snapping settles.
            settled = phase == .idle
            switch phase {
            case .interacting, .decelerating:
                if !userScrolling {
                    scrollDrivenSelectionID = nil
                }
                userScrolling = true
            case .idle:
                let wasScrolling = userScrolling
                userScrolling = false
                previewGeneration &+= 1
                if wasScrolling, !games.isEmpty, stride > 0 {
                    let offset = context.geometry.contentOffset.x + context.geometry.contentInsets.leading
                    let index = Self.nearestIndex(offset: offset, stride: stride, count: games.count)
                    scheduleScrollSelection(index: index, requireUserScrolling: false)
                }
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
            if chosen {
                if settled { primary(detail) }
                return
            }
            userScrolling = false
            previewGeneration &+= 1
            scrollDrivenSelectionID = detail.id
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
                scrollPosition.scrollTo(id: detail.id, anchor: anchor)
            }
            select(detail.id)
        } label: {
            CoverView(game: detail.game, radius: cover * 0.03, showsState: true)
                .frame(width: cover, height: cover * 9 / 16)
                .shadow(color: .black.opacity(0.5), radius: cover * 0.05, y: cover * 0.03)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Group {
                Button(ShellStrings.text("Play"), systemImage: "play.fill") { primary(detail) }
                    .disabled(detail.game.state != .playable)
                Button(ShellStrings.text("Game settings"), systemImage: "slider.horizontal.3") {
                    select(detail.id); openSettings()
                }
                if let openHomeScreen {
                    Button(ShellStrings.text("Add to Home Screen…"), systemImage: "plus.square") {
                        openHomeScreen(detail.id)
                    }
                }
                if let openCoverPicker {
                    Button(ShellStrings.text("Change Cover…"), systemImage: "photo.on.rectangle.angled") {
                        openCoverPicker(detail.id)
                    }
                }
                if let resetCover, detail.game.hasCustomCover {
                    Button(ShellStrings.text("Reset Cover"), systemImage: "arrow.uturn.backward") {
                        resetCover(detail.id)
                    }
                }
            }
        }
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
        GlyphHint(role: .shellSettings, label: ShellStrings.text("Settings"))
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
