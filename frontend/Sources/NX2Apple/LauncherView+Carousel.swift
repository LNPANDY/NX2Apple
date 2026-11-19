import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The library's Recently played row under the hero, its notices and the All games grid (LNPANDY/NX2Apple#1458). The row is the
/// carousel the library had before #1338 made it a grid: at most `recentLimit` games, most recently played first. Show all, in
/// the row's header and as the row's last card, opens All games: the whole library as the grid, with the filter, the order and
/// the count. Choosing a game there makes it the hero and returns to the row.
extension LauncherView {
    /// The row's length: a quick scan, the grid has the rest.
    static let recentLimit = 10

    /// The games of the row: the most recently played first, then by name (a build does not record its date).
    var recentGames: [LibraryGame] { Array(LibrarySort.recent.ordered(library.games, lang: loc.lang).prefix(Self.recentLimit)) }
    /// Show all is offered only when the row cannot hold every game.
    var hasMoreThanRecent: Bool { library.games.count > Self.recentLimit }
    /// The grid is up: Show all, or a search (the results are a grid too).
    var showsAllGames: Bool { allGamesOpen || !search.isEmpty }

    func openAllGames() {
        allGamesOpen = true
        if padFocus.visible { padFocus.focusAfterScroll("allGames.back") }
    }

    func closeAllGames() {
        allGamesOpen = false
        if !search.isEmpty || searching { search = ""; searching = false }
        if padFocus.visible { padFocus.focusAfterScroll(library.selectedID.map { "card." + $0.uuidString } ?? "library.showAll") }
    }

    /// A game chosen in the grid: the hero shows it, back in the library.
    func chooseFromAllGames(_ game: LibraryGame) {
        library.selectedID = game.id
        closeAllGames()
    }

    /// Everything the library tells the player outside a sheet, for the one notice slot under the top bar. `hero` adds what
    /// belongs to the hero's game (the row's page shows those, the grid does not).
    func libraryNotices(hero: LibraryGame?) -> [LauncherNoticeItem] {
        var items: [LauncherNoticeItem] = []
        if let syncing = EngineSyncBanner.notice(stores.engineSync, t: loc.t) { items.append(syncing) }
        if !stores.engineSync.syncing, let failure = stores.engineSync.failure {
            // The engine stopped: what happened and the next step. Try again where that is the fix, else Settings, whose Tools page
            // shows the full failure card with its fixes.
            let retry = failure.kind == .engineOffline || failure.kind == .engineSync
            items.append(LauncherNoticeItem(id: "engine.failure", tone: .error, title: m.failureWhat(failure), detail: loc.t(failure.kind.nextKey),
                action: retry ? .init(title: loc.t("fail.retry")) { stores.engineSync.retrySync() }
                              : .init(title: loc.t("nav.settings")) { settingsCategory = .tools; page = .settings }))
        }
        if library.showsSkippedBanner {
            let count = library.skippedItems.count
            items.append(LauncherNoticeItem(id: "library.skippedBanner", tone: .warning, symbol: "tray.full",
                title: count == 1 ? loc.t("macLibDiag.bannerOne") : String(format: loc.t("macLibDiag.bannerMany"), count),
                detail: loc.t("macLibDiag.bannerNote"),
                action: .init(title: loc.t("macLibDiag.details"), padID: "library.skippedBanner") { skippedItemsOpen = true },
                dismiss: (loc.t("library.dismissSkipped"), { library.dismissSkippedBanner() })))
        }
        guard let game = hero else { return items }
        if game.onDevice, let expiry = signatureExpiry[game.id], AppSignature.isUrgent(expiry) {
            items.append(LauncherNoticeItem(id: "hero.signature", tone: .warning, title: AppSignature.describe(expiry, loc.t)))
        }
        if !(m.running && activeBuildID == game.id), let note = heroRefreshNote(for: game) {
            items.append(LauncherNoticeItem(id: "hero.refresh", tone: .info, symbol: "arrow.triangle.2.circlepath", title: loc.t("engine.update"), detail: note))
        }
        if game.switch2EditionContentFound, !GameFolder.profileIsSwitch2(game.titleID, engineRoot: EngineLayout.root(m.repo.path)) {
            items.append(LauncherNoticeItem(id: "hero.switch2", tone: .info, title: loc.t("library.switch2Content")))   // #1057
        }
        if isLaunchingMacGame(game) && showGatekeeperHint {
            items.append(LauncherNoticeItem(id: "hero.gatekeeper", tone: .info, symbol: "checkmark.shield", title: loc.t("library.gatekeeperHint")))
        }
        if let resignNote {
            items.append(LauncherNoticeItem(id: "hero.resign", tone: .info, symbol: "signature", title: resignNote))
        }
        return items
    }

    /// The notice slot: aligned with the content's leading edge, as wide as a readable line.
    func noticeSlot(_ items: [LauncherNoticeItem]) -> some View {
        LauncherNoticeStack(items, enabled: artworkEditor == nil)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The row

    func recentRow(width: CGFloat) -> some View {
        let cardWidth = LibraryCarouselLayout.cardWidth(in: width)
        let games = recentGames
        let heroID = heroGame?.id
        let compact = width < Self.collectionWideHeaderWidth
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text(loc.t("library.recent")).font(DS.Font.title).tracking(DS.Font.titleTracking).lineLimit(1).fixedSize()
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                LauncherGlassGroup {
                    HStack(spacing: 8) {
                        if !library.games.isEmpty { collectionBatchRefreshButton(compact: compact) }
                        Button(loc.t("supported.title"), action: openSupportedGames)
                            .buttonStyle(LauncherSecondaryButtonStyle())
                            .padTarget("library.supported", scope: "main", activate: openSupportedGames)
                        if hasMoreThanRecent {
                            Button(action: openAllGames) {
                                HStack(spacing: 6) {
                                    Text(loc.t("library.showAll"))
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                                }
                            }
                            .buttonStyle(LauncherSecondaryButtonStyle())
                            .help(loc.t("library.allGames"))
                            .padTarget("library.showAll", scope: "main", activate: openAllGames)
                        }
                    }
                }
            }
            .id("library.collection.header")
            if games.isEmpty {
                HStack(alignment: .top, spacing: LibraryCardLayout.gridSpacing) {
                    ForEach(0..<LibraryCarouselLayout.placeholders(in: width, card: cardWidth), id: \.self) { _ in LibraryCarouselPlaceholder(width: cardWidth) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: LibraryCarouselLayout.spacing) {
                            ForEach(games) { game in
                                let _ = LauncherWork.count(.card)
                                collectionCard(game, width: cardWidth, selected: game.id == heroID, in: games, columns: nil)
                            }
                            if hasMoreThanRecent { showAllCard(width: cardWidth) }
                        }
                        // Room for the controller's focus ring and the hover lift: the row clips at its edges, so it gets the room
                        // inside and gives it back outside (the cards stay aligned with the header)
                        .padding(.horizontal, Self.ringRoom).padding(.vertical, Self.ringRoom + 4)
                        .background(EnclosingScrollView(row: rowScroller))
                    }
                    .padding(.horizontal, -Self.ringRoom).padding(.vertical, -(Self.ringRoom + 4))
                    .onChange(of: padFocus.focused) { id in
                        guard let id, id.hasPrefix("card.") || id == "library.showAllCard" else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: keyboardCard) { id in
                        if let id { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo("card." + id.uuidString, anchor: .center) } }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if rowScroller.canBack { pager("chevron.left", height: cardWidth / LibraryCardLayout.aspect) { rowScroller.page(-1, step: cardWidth + LibraryCarouselLayout.spacing) }.offset(x: -22) }
                }
                .overlay(alignment: .topTrailing) {
                    if rowScroller.canForward { pager("chevron.right", height: cardWidth / LibraryCardLayout.aspect) { rowScroller.page(1, step: cardWidth + LibraryCarouselLayout.spacing) }.offset(x: 22) }
                }
            }
        }
        .padding(.horizontal, 34).padding(.top, 8).padding(.bottom, 24)
    }

    /// The row's last card: the way to the rest of the library, in a card's footprint.
    private func showAllCard(width: CGFloat) -> some View {
        Button(action: openAllGames) {
            VStack(alignment: .leading, spacing: LibraryCardLayout.titleSpacing) {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 22, weight: .regular))
                    Text(String(format: loc.t("library.gameCount"), library.games.count)).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                }
                .foregroundStyle(LauncherPalette.text)
                .frame(width: width, height: width / LibraryCardLayout.aspect)
                .background(LauncherPalette.ink(0.05), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(LauncherPalette.cardBorder))
                Text(loc.t("library.showAll")).font(DS.Font.headline).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .padding(LibraryCardLayout.inset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil)
        .accessibilityLabel(loc.t("library.allGames"))
        .padTarget("library.showAllCard", scope: "main", radius: 7, activate: openAllGames)
    }

    /// A round glass button over the row's edge, centred on the artwork, shown while the row scrolls that way.
    private func pager(_ symbol: String, height: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(LauncherIconButtonStyle(size: 40))
            .shadow(color: .black.opacity(0.4), radius: 10)
            .frame(height: height)
            .accessibilityLabel(loc.t(symbol == "chevron.left" ? "library.scrollBack" : "library.scrollForward"))
            .transition(.opacity)
            .launcherGlassLayer()   // over the artwork: glass (#1458)
    }

    // MARK: All games

    func allGamesPage(size: CGSize) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    noticeSlot(libraryNotices(hero: nil)).padding(.top, 12)
                    collection(width: size.width)
                }
            }
            .onChange(of: padFocus.focused) { id in
                if let id, id.hasPrefix("card.") { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(id) } }
                else if ["library.sort", "library.filter", "library.supported", "allGames.back", "hero.rebuildAll"].contains(id ?? "") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("library.collection.header", anchor: .top) }
                }
            }
            .onChange(of: keyboardCard) { id in
                if let id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("card." + id.uuidString) } }
            }
        }
        .coordinateSpace(name: "library.scroll")
        .modifier(LibraryHeaderBar(header: libraryHeader))
    }

    /// The top bar of the library's pages. The engine's syncing and failure are notices in the slot under it.
    var libraryHeader: some View {
        topBar.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { libraryHeaderHeight = $0 }
    }

    /// The grid's header: back to the row, the title and the count, then the order and the filter.
    func allGamesHeader(count: Int, compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if allGamesOpen {
                Button(action: closeAllGames) { Image(systemName: "chevron.left") }
                    .buttonStyle(LauncherIconButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help(loc.t("library.backToLibrary")).accessibilityLabel(loc.t("library.backToLibrary"))
                    .padTarget("allGames.back", scope: "main", activate: closeAllGames)
            }
            Text(loc.t(allGamesOpen ? "library.allGames" : "library.yourLibrary")).font(DS.Font.title).tracking(DS.Font.titleTracking).lineLimit(1).fixedSize()
                .accessibilityAddTraits(.isHeader)
            Text(String(format: loc.t("library.gameCount"), count)).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(1).fixedSize()
        }
    }
}

/// The Recently played row's cards: wider than the grid's on a large window, as the carousel had them.
enum LibraryCarouselLayout {
    static let spacing: CGFloat = 4
    static func cardWidth(in available: CGFloat) -> CGFloat { min(300, max(190, (available - 124) / 5)) }
    /// How many placeholder cards fill the width of an empty library's row.
    static func placeholders(in available: CGFloat, card: CGFloat) -> Int {
        max(1, Int((max(0, available - 68) + LibraryCardLayout.gridSpacing) / (card + 2 * LibraryCardLayout.inset + LibraryCardLayout.gridSpacing)))
    }
}
