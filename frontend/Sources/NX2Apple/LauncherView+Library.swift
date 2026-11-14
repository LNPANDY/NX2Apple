import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The Library page of the launcher: the hero, the collection row and the status line of a game. A move out of LauncherView.swift
/// (LNPANDY/NX2Apple#387), the state stays in LauncherView.
extension LauncherView {
    var libraryPage: some View {
        GeometryReader { geometry in
            if library.games.isEmpty {
                emptyLibrary
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let game = heroGame {
                            // While the panel is open the hero is laid out at its size with the panel closed (the panel's
                            // width given back, the height it had) and scaled down to fit: same crop, same title, only smaller
                            let editing = artworkEditor != nil
                            let full = CGSize(width: geometry.size.width + (editing ? ArtworkPanel.width + 1 : 0),
                                              height: editing ? closedHeroHeight : max(240, geometry.size.height - collectionHeight))
                            let scale = min(1, geometry.size.width / full.width)
                            hero(game, width: full.width, height: full.height)
                                .scaleEffect(scale, anchor: .topLeading)
                                .frame(width: geometry.size.width, height: full.height * scale, alignment: .topLeading)
                                .opacity(dimmed(.hero))
                                .onAppear {
                                    closedHeroHeight = full.height
                                    artworkHeroAspect = full.width / full.height
                                }
                                .onChange(of: full) { size in
                                    if !editing { closedHeroHeight = size.height }
                                    artworkHeroAspect = size.width / size.height
                                }
                        }
                        // The hero takes what the collection leaves: the row's height grows with the window's width (its cards
                        // do, up to 300 pt), so a fixed share left a fullscreen window's cards cut off at the bottom
                        collection(width: geometry.size.width)
                            .background(GeometryReader { g in Color.clear.preference(key: CollectionHeightKey.self, value: g.size.height) })
                            .opacity(dimmed(.thumbnail))
                    }
                }
                .onPreferenceChange(CollectionHeightKey.self) { h in if h > 0, abs(h - collectionHeight) > 0.5 { collectionHeight = h } }
                .animation(.easeOut(duration: 0.18), value: artworkSlot)
                .onChange(of: library.selectedID) { _ in toolsAge.cancelSingleRefreshProbe() }
                .onChange(of: m.running) { running in if running { toolsAge.cancelSingleRefreshProbe() } }
                .onDisappear { toolsAge.cancelSingleRefreshProbe() }
            }
        }
    }

    var emptyLibrary: some View {
        let hasSkipped = library.showsSkippedBanner
        return VStack(alignment: .leading, spacing: hasSkipped ? 16 : 22) {
            Spacer()
            Image(systemName: "gamecontroller").font(.system(size: 44, weight: .light))
                .foregroundStyle(LauncherPalette.cream)
            Text(loc.t("library.welcome")).font(.manrope(54, .bold)).tracking(-1.8)
            Text(loc.t("library.welcomeNote")).font(.manrope(17)).foregroundStyle(.secondary)
                .frame(maxWidth: 490, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Button { newBuild() } label: {
                Label(loc.t("library.firstBuild"), systemImage: "plus")
                    .font(.manrope(16, .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 15)
            }
            .buttonStyle(LauncherActionButtonStyle()).launcherHover(enabled: artworkEditor == nil, lightBrightness: 0).padding(.top, hasSkipped ? 4 : 8)
            Button(action: chooseLibraryFolder) {
                Label(loc.t("library.chooseFolder"), systemImage: "folder")
                    .font(.manrope(14)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil)
            Button(action: openSupportedGames) {
                Label(loc.t("supported.menu"), systemImage: "list.bullet.rectangle")
                    .font(.manrope(14)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil)
            if hasSkipped {
                LibrarySkippedBanner(
                    items: library.skippedItems,
                    enabled: artworkEditor == nil,
                    openDetails: { skippedItemsOpen = true },
                    dismiss: { library.dismissSkippedBanner() }
                )
                .frame(maxWidth: 660)
                .padding(.top, 4)
            }
            Spacer()
            Text(loc.t("library.localNote")).font(.manrope(12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 48).padding(.vertical, hasSkipped ? 28 : 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    func hero(_ game: LibraryGame, width: CGFloat, height: CGFloat) -> some View {
        let lightHero = colorScheme == .light
        return ZStack(alignment: .bottomLeading) {
            ZStack {
                if let image = heroImage(for: game) {
                    ArtworkFill(image: image, focus: displayed(game).artwork.focus(for: .hero))
                } else {
                    LauncherPalette.surface
                    Image(systemName: "gamecontroller").font(.system(size: 160, weight: .ultraLight))
                        .foregroundStyle(LauncherPalette.ink(0.05))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(60)
                }
            }
            .frame(width: width, height: max(0, height - 1)).clipped()
            .frame(width: width, height: height, alignment: .top)
            if lightHero {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .clear, location: 0.44),
                                       .init(color: LauncherPalette.background.opacity(0.68), location: 0.62),
                                       .init(color: LauncherPalette.background.opacity(0.92), location: 0.78),
                                       .init(color: LauncherPalette.background, location: 0.96),
                                       .init(color: LauncherPalette.background, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(stops: [.init(color: .clear, location: 0.25),
                                       .init(color: .black.opacity(0.25), location: 0.45),
                                       .init(color: LauncherPalette.background, location: 0.98),
                                       .init(color: LauncherPalette.background, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.24), .clear], startPoint: .leading, endPoint: .trailing)
            }
            VStack(alignment: .leading, spacing: 14) {
                heroStatusHeader(game, lightHero: lightHero)
                Text(game.displayName(loc.lang)).font(.manrope(min(68, width * 0.052), .heavy))
                    .tracking(-1.6).lineLimit(2)
                    .shadow(color: lightHero ? .white.opacity(0.55) : .black.opacity(0.25), radius: 12)
                HStack(alignment: width < 760 ? .top : .center, spacing: 18) {
                    heroPrimary(game, compact: width < 760)
                    if game.isReady {
                        Button { optionsFor = game.id } label: {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 17))
                                .foregroundStyle(LauncherPalette.textStrong)
                                .frame(width: 48, height: 48)
                                .background(lightHero ? Color.white.opacity(0.82) : Color.white.opacity(0.10), in: Circle())
                                .overlay(Circle().strokeBorder(lightHero ? Color.black.opacity(0.12) : Color.white.opacity(0.14)))
                        }
                        .buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil).help(loc.t("launch.title")).accessibilityLabel(loc.t("launch.title"))
                        .padTarget("hero.options", scope: "main", radius: 24) { optionsFor = game.id }
                    }
                    Button { manageOpenFor = manageOpenFor == nil ? game.id : nil } label: { ManageButtonLabel(title: loc.t("library.manage")) }
                        .buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil).accessibilityLabel(loc.t("library.manage"))
                        .anchorPreference(key: ManageAnchorKey.self, value: .bounds) { $0 }
                        .padTarget("hero.manage", scope: "main", radius: 12) { manageOpenFor = game.id }
                }
                if isLaunchingMacGame(game) && showGatekeeperHint {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LauncherPalette.cream.opacity(0.85))
                        Text(loc.t("library.gatekeeperHint"))
                            .font(.manrope(12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !(m.running && activeBuildID == game.id), let refreshNote = heroRefreshNote(for: game) {
                    Text(refreshNote)
                        .font(.manrope(12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if game.switch2EditionContentFound, !GameFolder.profileIsSwitch2(game.titleID, engineRoot: EngineLayout.root(m.repo.path)) {
                    Text(loc.t("library.switch2Content")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if verifiedProfiles.isUnverified(game) {
                    HStack(spacing: 7) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(LauncherPalette.cream.opacity(0.68))
                        Text(loc.t("macLibVerify.note"))
                            .font(.manrope(12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // A free Apple ID's provisioning profile lasts 7 days. Say when this app's runs out, and offer the
                // re-sign at any time: renewing early (before a trip, say) is as valid as renewing just in time.
                if game.onDevice && !game.isOlderIOSBuild {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal").font(.system(size: 12))
                            .foregroundStyle(LauncherPalette.cream.opacity(0.7))
                        Text(signatureExpiry[game.id].map { AppSignature.describe($0, loc.t) } ?? loc.t("dev.expiryUnknown"))
                            .font(.manrope(12.5))
                            .foregroundStyle(signatureExpiry[game.id].map { AppSignature.isUrgent($0) } == true
                                             ? LauncherPalette.building : .secondary)
                        Button { resign(game) } label: {
                            Text(loc.t("dev.resign")).font(.manrope(12, .semibold))
                                .foregroundStyle(LauncherPalette.cream)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .overlay(Capsule().strokeBorder(LauncherPalette.cream.opacity(0.35)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil).disabled(m.running)
                        .help(loc.t("dev.resignHelp"))
                        .padTarget("hero.resign", scope: "main", radius: 12) { if !m.running { resign(game) } }
                    }
                }
                if let resignNote {
                    Text(resignNote).font(.manrope(12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 34).padding(.bottom, 34)
        }
        .frame(width: width, height: height).clipped()
    }

    /// Adaptive status and refresh pill header at the top of the hero banner.
    @ViewBuilder private func heroStatusHeader(_ game: LibraryGame, lightHero: Bool) -> some View {
        let isBuildingThis = m.running && activeBuildID == game.id
        let hasActions = !isBuildingThis && heroShowsAnyRefreshPill(game)
        if hasActions {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    heroStatusBadge(game, lightHero: lightHero)
                    heroRefreshPills(game, lightHero: lightHero)
                }
                VStack(alignment: .leading, spacing: 8) {
                    heroStatusBadge(game, lightHero: lightHero)
                    HStack(spacing: 10) {
                        heroRefreshPills(game, lightHero: lightHero)
                    }
                }
            }
        } else {
            heroStatusBadge(game, lightHero: lightHero)
        }
    }

    @ViewBuilder private func heroStatusBadge(_ game: LibraryGame, lightHero: Bool) -> some View {
        if lightHero {
            status(game, prominent: true)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background {
                    Capsule().fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(Color.white.opacity(0.76)))
                }
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.10)))
                .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
        } else {
            status(game, prominent: true)
        }
    }

    private func heroShowsAnyRefreshPill(_ game: LibraryGame) -> Bool {
        if gameNeedsRefresh(game) { return true }
        return refreshableGames.contains { $0.id != game.id }
    }

    @ViewBuilder private func heroRefreshPills(_ game: LibraryGame, lightHero: Bool) -> some View {
        let assessment = toolsAge.assessments[game.id]
        if gameNeedsRefresh(game) {
            let primarySpec = heroPrimaryRefreshSpec(assessment: assessment)
            heroActionPill(
                title: primarySpec.title,
                symbol: primarySpec.symbol,
                id: "hero.rebuild",
                frosted: lightHero
            ) {
                triggerSingleRefresh(game)
            }
            if assessment != nil {
                let total = refreshableGames.count
                if total > 1 {
                    heroActionPill(
                        title: String(format: loc.t("library.refresh.batchBtn"), total),
                        symbol: "square.stack.3d.up",
                        id: "hero.rebuildAll",
                        frosted: lightHero
                    ) {
                        openBatchRefresh()
                    }
                }
            } else {
                let legacyCount = olderToolsGames.count
                if legacyCount > 1 {
                    heroActionPill(
                        title: String(format: loc.t("library.rebuildAll"), legacyCount),
                        symbol: "arrow.clockwise",
                        id: "hero.rebuildAll",
                        frosted: lightHero
                    ) {
                        openBatchRefresh()
                    }
                }
            }
        } else {
            let otherCount = refreshableGames.filter { $0.id != game.id }.count
            if otherCount > 0 {
                heroActionPill(
                    title: String(format: loc.t("library.refresh.batchOthersBtn"), otherCount),
                    symbol: "square.stack.3d.up",
                    id: "hero.rebuildAll",
                    frosted: lightHero
                ) {
                    openBatchRefresh()
                }
            }
        }
    }

    private func heroPrimaryRefreshSpec(assessment: GameRefreshAssessment?) -> (title: String, symbol: String) {
        guard let assessment else {
            return (loc.t("library.rebuildShort"), "arrow.clockwise")
        }
        switch assessment.heroState {
        case .specificFast:
            return (loc.t("library.refresh.fastBtn"), "bolt.fill")
        case .specificFull:
            return (loc.t("library.refresh.rebuildBtn"), "arrow.clockwise")
        case .generalSync(let fast):
            if fast {
                return (loc.t("library.refresh.fastSyncBtn"), "bolt.fill")
            }
            return (loc.t("library.refresh.syncBtn"), "arrow.clockwise")
        case .upToDate:
            return (loc.t("library.rebuildShort"), "arrow.clockwise")
        }
    }

    private func heroRefreshNote(for game: LibraryGame) -> String? {
        if let assessment = toolsAge.assessments[game.id] {
            switch assessment.heroState {
            case .specificFast(let version):
                return String(format: loc.t("library.refresh.noteSpecificFast"), game.displayName(loc.lang), version)
            case .specificFull:
                return loc.t("library.refresh.noteSpecificFull")
            case .generalSync:
                return loc.t("library.refresh.noteGeneral")
            case .upToDate:
                return nil
            }
        }
        if toolsAge.older.contains(game.id) {
            return loc.t("library.olderToolsSafeNote")
        }
        return nil
    }

    /// The way to the Supported games sheet in the collection's header, before Sort: the list is about the library, not about one game.
    /// The secondary button style, as high as the Sort menu beside it. Below `supportedLabelWidth` the header has no room for the words
    /// in every language, and the button keeps its symbol, with the name as its tooltip and accessible label.
    func supportedGamesButton(compact: Bool) -> some View {
        Button(action: openSupportedGames) {
            // the style adds 9 pt above and below the label: 18 more makes it as high as Sort
            if compact {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 13, weight: .semibold)).frame(height: LauncherControl.height - 18)
            } else {
                Label(loc.t("supported.title"), systemImage: "list.bullet.rectangle").frame(height: LauncherControl.height - 18)
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
        .help(loc.t("supported.title")).accessibilityLabel(loc.t("supported.title"))
        .padTarget("library.supported", scope: "main", radius: 9, activate: openSupportedGames)
    }

    /// The window width from which the Supported games button shows its name.
    static let supportedLabelWidth: CGFloat = 1100

    func collection(width: CGFloat) -> some View {
        let cardWidth = min(300, max(190, (width - 124) / 5))
        let step = cardWidth + 14
        let games = filteredGames
        let heroID = heroGame?.id
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Text(loc.t("library.collection")).font(.manrope(28, .bold)).tracking(-0.6)
                Spacer()
                let compactHeader = width < Self.supportedLabelWidth
                supportedGamesButton(compact: compactHeader)
                HStack(spacing: 8) {
                    // a narrow window keeps the menu without the word before it (the menu's accessible label says Sort)
                    if !compactHeader { Text(loc.t("sort.label")).font(.manrope(12)).foregroundStyle(.secondary).fixedSize() }
                    LauncherDropdown(options: LibrarySort.allCases.map { ($0.rawValue, loc.t($0.labelKey)) }, selection: librarySort.rawValue,
                                     label: loc.t("sort.label"), style: .button) { setLibrarySort(LibrarySort(rawValue: $0) ?? .recent) }
                        .padTarget("library.sort", scope: "main", radius: 9,
                                   activate: { setLibrarySort(librarySort == .recent ? .name : .recent) },
                                   adjust: { setLibrarySort($0 > 0 ? .name : .recent) })
                }
                LauncherSegmented(options: LibraryFilter.allCases.map { ($0.rawValue, loc.t($0.labelKey)) },
                                  selection: libraryFilter.rawValue) { setLibraryFilter(LibraryFilter(rawValue: $0) ?? .owned) }
                    .frame(width: LauncherControl.width)
                    .padTarget("library.filter", scope: "main", radius: 17,
                               activate: { setLibraryFilter(libraryFilter == .owned ? .built : .owned) },
                               adjust: { setLibraryFilter($0 > 0 ? .built : .owned) })
                Text(String(format: loc.t("library.gameCount"), libraryFilter == .owned ? library.games.count : library.games.filter(libraryFilter.includes).count))
                    .font(.manrope(12)).foregroundStyle(.secondary)
            }
            if library.showsSkippedBanner {
                LibrarySkippedBanner(
                    items: library.skippedItems,
                    enabled: artworkEditor == nil,
                    openDetails: { skippedItemsOpen = true },
                    dismiss: { library.dismissSkippedBanner() }
                )
            }
            if games.isEmpty {
                Text(loc.t("library.noResults")).foregroundStyle(.secondary).padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(games) { game in
                                let _ = LauncherWork.count(.card)
                                Button { library.selectedID = game.id } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ZStack {
                                            if let image = artwork[game.id] {
                                                ArtworkFill(image: image, focus: displayed(game).artwork.focus(for: .thumbnail))
                                            } else {
                                                LauncherPalette.surface
                                                Image(systemName: "gamecontroller").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(width: cardWidth, height: cardWidth / 1.8).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                                            game.id == heroID
                                                ? (colorScheme == .light ? LauncherPalette.focusRing : LauncherPalette.cream)
                                                : (colorScheme == .light ? LauncherPalette.cardBorder : .clear),
                                            lineWidth: game.id == heroID ? (colorScheme == .light ? 1.5 : 2) : 1))
                                        Text(game.displayName(loc.lang)).font(.manrope(16, .semibold)).lineLimit(1)
                                        status(game)
                                        Capsule().fill(game.id == heroID ? LauncherPalette.selectionUnderline : .clear)
                                            .frame(height: LauncherPalette.selectionUnderlineHeight).padding(.top, 4)
                                    }
                                    .frame(width: cardWidth, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil)
                                .accessibilityAddTraits(game.id == heroID ? .isSelected : [])
                                .padTarget("card." + game.id.uuidString, scope: "main", radius: 7) { if !launching { primaryAction(game) } }
                            }
                        }
                        // Room for the controller's focus ring, which sits 4 pt outside a card: the row clips at its edges, so it
                        // gets the room inside and gives it back outside (the cards stay where they were)
                        .padding(.horizontal, Self.ringRoom).padding(.top, Self.ringRoom).padding(.bottom, 5 + Self.ringRoom)
                        .background(EnclosingScrollView(row: row))
                    }
                    .padding(.horizontal, -Self.ringRoom).padding(.vertical, -Self.ringRoom)
                    .onChange(of: padFocus.focused) { id in
                        guard let id, id.hasPrefix("card.") else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if row.canBack {
                        pager("chevron.left", height: cardWidth / 1.8) { row.page(-1, step: step) }.offset(x: -22)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if row.canForward {
                        pager("chevron.right", height: cardWidth / 1.8) { row.page(1, step: step) }.offset(x: 22)
                    }
                }
            }
        }
        .padding(.horizontal, 34).padding(.top, 8).padding(.bottom, 22)
    }

    /// A round button floating over the row's edge, centred on the artwork, shown while the row scrolls that way.
    func pager(_ symbol: String, height: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.72), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16)))
                .shadow(color: .black.opacity(0.4), radius: 10)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil)
        .frame(height: height)
        .accessibilityLabel(loc.t(symbol == "chevron.left" ? "library.scrollBack" : "library.scrollForward"))
        .transition(.opacity)
    }

    /// The games built with older tools that can be built again from the files the library holds.
    var olderToolsGames: [LibraryGame] {
        library.games.filter { toolsAge.older.contains($0.id) && !$0.inputs["base", default: []].isEmpty }
    }

    /// Whether a game has a pending engine or profile refresh.
    func gameNeedsRefresh(_ game: LibraryGame) -> Bool {
        if let assessment = toolsAge.assessments[game.id] {
            return assessment.heroState != .upToDate
        }
        return toolsAge.older.contains(game.id)
    }

    /// All built games in the library that currently have a pending refresh.
    var refreshableGames: [LibraryGame] {
        library.games.filter { item in
            if let assessment = toolsAge.assessments[item.id] {
                return assessment.heroState != .upToDate
            }
            return toolsAge.older.contains(item.id)
                && (item.isReady || item.hasIOSBuild || !item.inputs["base", default: []].isEmpty || item.inputs[GameLibrary.folderInput] != nil)
        }
    }

    /// Outlined capsule button in the hero's top status row for single-game or batch refresh.
    func heroActionPill(title: String, symbol: String, id: String, frosted: Bool = false, action: @escaping () -> Void) -> some View {
        let isProbing = toolsAge.singleRefreshProbingGameID != nil
        let perform = {
            guard !m.running, !isProbing else { return }
            action()
        }
        return Button(action: perform) {
            Label(title, systemImage: symbol)
                .font(.manrope(12, .semibold)).foregroundStyle(LauncherPalette.cream)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background {
                    if frosted {
                        Capsule().fill(.ultraThinMaterial)
                            .overlay(Capsule().fill(Color.white.opacity(0.76)))
                    }
                }
                .overlay(Capsule().strokeBorder(LauncherPalette.cream.opacity(frosted ? 0.25 : 0.35)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil && !isProbing).disabled(m.running || isProbing)
        .help(loc.t("library.olderToolsHelp"))
        .padTarget(id, scope: "main", radius: 12, activate: perform)
    }

    private func openBatchRefresh() {
        toolsAge.cancelSingleRefreshProbe()
        batchRefreshOpen = true
    }

    func triggerSingleRefresh(_ game: LibraryGame) {
        guard !stores.build.running else {
            page = .builds
            return
        }
        guard toolsAge.singleRefreshProbingGameID == nil else { return }
        let assessment = toolsAge.assessments[game.id]
        if game.hasIOSBuild, let assessment, assessment.needsMissingImgGuideIOS {
            let driveFolder = devices.driveFolder
            if !driveFolder.isEmpty {
                toolsAge.singleRefreshProbeGeneration &+= 1
                let probeGen = toolsAge.singleRefreshProbeGeneration
                let selectedSnapshot = library.selectedID
                let heroSnapshot = heroGame?.id
                toolsAge.singleRefreshProbingGameID = game.id
                let tid = game.titleID
                let expected = assessment.expectedRomfsIdentity
                DispatchQueue.global(qos: .userInitiated).async {
                    let foundImg = RomfsImageIdentity.scanExternalDriveForMatchingImage(
                        driveFolder: driveFolder,
                        titleID: tid,
                        expectedIdentity: expected
                    )
                    DispatchQueue.main.async {
                        guard probeGen == toolsAge.singleRefreshProbeGeneration else { return }
                        toolsAge.singleRefreshProbingGameID = nil
                        guard !stores.build.running,
                              page == .library,
                              library.selectedID == selectedSnapshot,
                              heroGame?.id == heroSnapshot,
                              library.games.contains(where: { $0.id == game.id }),
                              missingImgGuideFor == nil,
                              !batchRefreshOpen else { return }
                        if let foundImg {
                            enqueueSingleGameRefresh(game, assessment: assessment, externalIOSImgPath: foundImg)
                        } else {
                            missingImgGuideFor = MissingImgGuideContext(game: game, assessment: assessment)
                        }
                    }
                }
            } else {
                missingImgGuideFor = MissingImgGuideContext(game: game, assessment: assessment)
            }
            return
        }
        enqueueSingleGameRefresh(game, assessment: assessment, externalIOSImgPath: nil)
    }

    func enqueueSingleGameRefresh(_ game: LibraryGame, assessment: GameRefreshAssessment?, externalIOSImgPath: String?) {
        let batch = UUID()
        var entries: [QueueEntry] = []
        let hasMac = game.isReady
        let hasIOS = game.hasIOSBuild

        if hasMac {
            let fastMac = assessment?.canFastRefreshMac ?? false
            if fastMac || assessment?.missingOriginalPackage != true {
                entries.append(RefreshQueueBuilder.makeEntry(
                    game: game,
                    target: BuildTarget.mac,
                    fastRefresh: fastMac,
                    externalImgPath: nil,
                    batch: batch,
                    stores: stores,
                    libraryFolder: library.folder
                ))
            }
        }

        if hasIOS {
            let fastIOS = (assessment?.canFastRefreshIOS ?? false) || externalIOSImgPath != nil
            if fastIOS || assessment?.missingOriginalPackage != true {
                entries.append(RefreshQueueBuilder.makeEntry(
                    game: game,
                    target: BuildTarget.ios,
                    fastRefresh: fastIOS,
                    externalImgPath: externalIOSImgPath,
                    batch: batch,
                    stores: stores,
                    libraryFolder: library.folder
                ))
            }
        }

        if !hasMac && !hasIOS {
            if !game.inputs["base", default: []].isEmpty || game.inputs[GameLibrary.folderInput] != nil {
                entries.append(QueueEntry(
                    game: game,
                    engineID: stores.engineSync.selection.engineID,
                    target: m.target,
                    batch: batch,
                    packageAfter: m.target != BuildTarget.mac && !m.exportsOneGame
                ))
            }
        }

        let ordered = RefreshQueueBuilder.orderedEntries(entries)
        guard !ordered.isEmpty else {
            configureBuild(game)
            return
        }
        stores.queue.enqueue(ordered)
        page = .builds
        if !m.running && m.canStartBuildOrQueue {
            m.startBuildOrQueue()
        }
    }

    func status(_ game: LibraryGame, prominent: Bool = false) -> some View {
        let building = m.running && activeBuildID == game.id
        let color = building ? LauncherPalette.building : ((game.isReady || game.hasIOSBuild) ? LauncherPalette.ready : LauncherPalette.unbuilt)
        let key: String
        if building {
            key = "library.building"
        } else if game.isReady && game.hasIOSBuild {
            key = "library.readyMacAndIOS"
        } else if game.isReady {
            key = "library.ready"
        } else if game.hasIOSBuild {
            key = game.onDevice ? "library.readyOnIOS" : (game.isOlderIOSBuild ? "library.olderIOS" : "library.readyIOS")
        } else {
            key = "library.notBuilt"
        }
        return HStack(spacing: 7) {
            Circle().fill(color).frame(width: prominent ? 9 : 7, height: prominent ? 9 : 7)
            Text(prominent ? loc.t(key).uppercased() : loc.t(key))
                .font(prominent ? .manrope(12, .bold) : .manrope(13, .medium))
                .tracking(prominent ? 1.3 : 0)
                .foregroundStyle(color)
            if GameFolder.profileIsSwitch2(game.titleID, engineRoot: EngineLayout.root(m.repo.path)) {
                Text(loc.t("switch2.badge"))
                    .font(.manrope(prominent ? 11 : 10.5, .bold)).foregroundStyle(LauncherPalette.notice)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(LauncherPalette.noticeBorder))
                    .help(loc.t("switch2.help"))
            }
            if prominent && verifiedProfiles.isUnverified(game) {
                Text(loc.t("macLibVerify.badge"))
                    .font(.manrope(11, .semibold))
                    .foregroundStyle(LauncherPalette.cream.opacity(0.84))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(LauncherPalette.ink(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(LauncherPalette.ink(0.18)))
                    .help(loc.t("macLibVerify.note"))
            }
            if !building {
                statusRefreshSuffix(game, prominent: prominent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func statusRefreshSuffix(_ game: LibraryGame, prominent: Bool) -> some View {
        if prominent {
            if let assessment = toolsAge.assessments[game.id] {
                switch assessment.heroState {
                case .specificFast(let version), .specificFull(let version):
                    Text("· " + String(format: loc.t("library.refresh.badgeVersion"), version))
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(LauncherPalette.notice)
                        .lineLimit(1)
                        .help(loc.t("library.olderToolsHelp"))
                case .generalSync:
                    Text("· " + loc.t("library.refresh.badgeGeneral"))
                        .font(.manrope(13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(loc.t("library.olderToolsHelp"))
                case .upToDate:
                    if toolsAge.older.contains(game.id) {
                        Text("· " + loc.t("library.olderTools"))
                            .font(.manrope(13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(loc.t("library.olderToolsHelp"))
                    }
                }
            } else if toolsAge.older.contains(game.id) {
                Text("· " + loc.t("library.olderTools"))
                    .font(.manrope(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(loc.t("library.olderToolsHelp"))
            }
        } else {
            let needsBadge = toolsAge.assessments[game.id].map { $0.heroState != .upToDate } ?? toolsAge.older.contains(game.id)
            if needsBadge {
                Text("· " + loc.t("library.olderToolsShort"))
                    .font(.manrope(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(loc.t("library.olderToolsHelp"))
            }
        }
    }
}
