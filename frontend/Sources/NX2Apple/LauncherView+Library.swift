import SwiftUI
import CoreText
import NXCore
import NXModel
import NXLauncher

/// The Library page of the launcher: the hero, the collection grid and the status line of a game. A move out of LauncherView.swift
/// (LNPANDY/NX2Apple#387), the state stays in LauncherView.
extension LauncherView {
    private var libraryReservedHeaderHeight: CGFloat {
        libraryHeaderHeight + 1   // the solid bar and its hairline sit above the hero on every macOS (#1458)
    }

    var libraryPage: some View {
        GeometryReader { geometry in
            if showsAllGames {
                allGamesPage(size: geometry.size)
            } else {
                recentPage(geometry)
            }
        }
    }

    /// The hero of the selected game, the Recently played row under it. The hero takes what the row leaves, the row's height
    /// grows with the window's width (its cards do, up to 300 pt).
    private func recentPage(_ geometry: GeometryProxy) -> some View {
        let editing = artworkEditor != nil
        let width = max(0, geometry.size.width - (editing ? ArtworkPanel.width + 1 : 0))
        let row = recentRowHeight > 0 ? recentRowHeight : 124 + LibraryCarouselLayout.cardWidth(in: geometry.size.width) / LibraryCardLayout.aspect
        let hero = heroGame
        return ScrollViewReader { proxy in
            ScrollView {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        let full = CGSize(width: geometry.size.width,
                            height: editing ? closedHeroHeight : max(LibraryHeroLayout.height(available: 0, hasDeviceActions: library.games.contains { !$0.installedDevice.isEmpty }),
                                                                     geometry.size.height - libraryReservedHeaderHeight - row))
                        let scale = min(1, width / max(1, full.width))
                        self.hero(hero, width: full.width, height: full.height)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: width, height: editing ? full.height * scale : nil, alignment: .topLeading)
                            .opacity(dimmed(.hero))
                            .overlay(alignment: .topLeading) {   // the notice slot, under the top bar
                                if !editing { noticeSlot(libraryNotices(hero: hero)).padding(.top, DS.Space.s) }
                            }
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                                if !editing {
                                    if abs(size.height - closedHeroHeight) > 0.5 { closedHeroHeight = size.height }
                                    let aspect = size.width / max(1, size.height)
                                    if abs(aspect - artworkHeroAspect) > 0.001 { artworkHeroAspect = aspect }
                                }
                            }
                        recentRow(width: width)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                if abs(height - recentRowHeight) > 0.5 { recentRowHeight = height }
                            }
                            .opacity(dimmed(.thumbnail))
                    }.frame(width: width)
                    if editing { Color.clear.frame(width: ArtworkPanel.width + 1) }
                }
            }
            .onChange(of: padFocus.focused) { id in
                if let id, id.hasPrefix("card.") || id.hasPrefix("library."), let frame = padFocus.frame(of: id),
                   frame.minY < libraryHeaderHeight || frame.maxY > geometry.size.height {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("library.collection.header", anchor: .top) }
                }
            }
        }
        .coordinateSpace(name: "library.scroll")
        .modifier(LibraryScrollUnderlap())
        .animation(.easeOut(duration: 0.18), value: artworkSlot)
        .onChange(of: library.selectedID) { _ in toolsAge.cancelSingleRefreshProbe() }
        .onChange(of: m.running) { running in
            library.invalidateArtworkStates()
            if running { toolsAge.cancelSingleRefreshProbe() }
        }
        .onChange(of: activeBuildID) { _ in library.invalidateArtworkStates() }
        .onChange(of: buildQueue.entries) { _ in library.invalidateArtworkStates() }
        .onDisappear { toolsAge.cancelSingleRefreshProbe() }
        .allowsHitTesting(!editing)
        .overlay(alignment: .trailing) {
            if let editor = artworkEditor {
                HStack(spacing: 0) {
                    Divider().opacity(0.3)
                    ArtworkPanel(editor: editor, labels: loc.t, save: { closeArtwork(save: true) }, cancel: { closeArtwork(save: false) })
                        .onReceive(editor.$draft) { refreshPreview($0) }
                        .onReceive(editor.$slot) { artworkSlot = $0 }
                        .onChange(of: artworkHeroAspect) { editor.heroAspect = $0 }
                }.frame(width: ArtworkPanel.width + 1)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .modifier(LibraryHeaderBar(header: libraryHeader))
    }

    func hero(_ game: LibraryGame?, width: CGFloat, height: CGFloat) -> some View {
        let layout = LibraryHeroLayout.content(width: width, height: height, headerHeight: 0)   // the hero starts below the bar
        let titleSize = layout.titleSize
        let titleTopInset = Typography.manropeFont(size: titleSize, weight: .heavy).map { max(0, CTFontGetAscent($0) - CTFontGetCapHeight($0)) } ?? 0
        let contentGap = layout.columnGap
        let textWidth = max(0, width - 68)   // no cover tile beside the title (#1458): the text starts at the content edge
        return ZStack(alignment: .bottomLeading) {
            GeometryReader { position in
                let pull = max(0, position.frame(in: .named("library.scroll")).minY)
                let backdropHeight = max(height, position.size.height)
                ZStack {
                    ZStack {
                        if let game, let image = heroImage(for: game) {
                            let state = library.artworkState(for: game, building: isBuildingGame(game), queued: isQueuedGame(game))
                            ArtworkFill(image: image, focus: displayed(game).artwork.focus(for: .hero))
                                .saturation(LibraryArtworkTone.saturation(muted: state.monochrome))   // sharp, never blurred (#1458)
                                .id(game.id).transition(.opacity)
                        } else {
                            LibraryFallbackArtwork(size: CGSize(width: width + 96, height: backdropHeight + pull + 96))
                        }
                    }
                    .animation(LibraryHeroTransition.artwork(reduceMotion: reduceMotion), value: game?.id)
                    .frame(width: width + 96, height: backdropHeight + pull + 96)
                    .frame(width: width, height: max(0, backdropHeight + pull - 1)).clipped()
                    .frame(width: width, height: backdropHeight + pull, alignment: .top)
                    // The artwork sharp, not blurred (#1458): dimmed at the top under the bar, darker behind the title on the left, and
                    // fading into the page at the bottom, where the row of games starts.
                    LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0),
                                           .init(color: .black.opacity(0.1), location: 0.22),
                                           .init(color: .black.opacity(0.25), location: 0.5),
                                           .init(color: LauncherPalette.background.opacity(0.92), location: 0.86),
                                           .init(color: LauncherPalette.background, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                    LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .black.opacity(0.2), location: 0.55),
                                           .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                }.frame(width: width, height: backdropHeight + pull)
                .background(LauncherPalette.background)
                .offset(y: -pull)
            }.allowsHitTesting(false)
            Group {
                if let game {
                    HStack(alignment: .bottom, spacing: contentGap) {
                        VStack(alignment: .leading, spacing: layout.titleActionGap) {
                            VStack(alignment: .leading, spacing: layout.badgeTitleGap) {
                                heroBadges(game)
                                ZStack(alignment: .bottomLeading) {
                                    Text(game.displayName(loc.lang)).font(.manrope(titleSize, .heavy))
                                        .accessibilityLabel(game.displayName(loc.lang))
                                        .tracking(-1).lineLimit(3).minimumScaleFactor(0.85)
                                        .fixedSize(horizontal: false, vertical: true)
                                        // Trim the font's space above capitals without changing the title-to-action gap.
                                        .padding(.top, -titleTopInset)
                                        .shadow(color: .black.opacity(0.3), radius: 12)
                                        .frame(width: textWidth, alignment: .leading)
                                        .id(game.id).transition(.opacity)
                                }
                                .animation(LibraryHeroTransition.metadata(reduceMotion: reduceMotion), value: game.id)
                                if game.playableMacBundle?.upstream == .nxkit {
                                    // A quiet property under the title (#1460): nxkit (Beta) built this app
                                    Label(loc.t("nxkit.builtWith"), systemImage: "hammer")
                                        .font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                                        .help(m.nxkitRecord(game.titleID).map { String(format: loc.t("nxkit.version"), $0.version) } ?? loc.t("nxkit.builtWith"))
                                        .accessibilityIdentifier("hero.nxkit")
                                }
                            }
                            heroActions(game, compact: width < 760)
                            if let generic = nxkitGenericBuild(game) {
                                // built without a game profile (v0lumehi/nxkit#54): it may not start or render wrong, said every time
                                NxkitGenericBuildRow(profile: generic.profile, makeReportURL: generic.makeReport)
                                    .frame(maxWidth: 620, alignment: .leading)
                            }
                            if let prompt = nxkitLaunchPrompt(game) {
                                // "Did it work?" after the first start of an app nxkit built, once (#1460)
                                NxkitFeedbackRow(prompt: prompt) { m.markNxkitFeedbackAsked(prompt.id) }
                                    .frame(maxWidth: 620, alignment: .leading)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 34).padding(.bottom, 24)
                } else {
                    emptyLibraryHero(width: width)
                }
            }.transaction { $0.animation = nil }
        }
        .frame(width: width).frame(minHeight: height, alignment: .bottomLeading)
        .task(id: "\(game?.id.uuidString ?? "")|\(loc.lang.code)|\(game?.appPath ?? "")") {
            guard let game else {
                heroIcon = nil
                return
            }
            let banners = library.artworkDirectory
            let fallbackKeys = library.keysFile()
            let langCode = loc.lang.code
            if let offline = await GameLibrary.loadAppIcon(
                for: game,
                banners: banners,
                language: langCode,
                fallbackKeys: fallbackKeys,
                maxPixel: ArtworkImages.iconPixels
            ) {
                guard !Task.isCancelled, heroGame?.id == game.id else { return }
                heroIcon = (game.id, offline)
            }
            guard performStartupChecks || artworkStore !== ArtworkStore.shared else { return }
            if let url = await artworkStore.fetchIcon(game.titleID, language: langCode) {
                ArtworkImages.shared.invalidate(at: url)
                let online = await ArtworkImages.shared.loadImage(at: url, maxPixel: ArtworkImages.iconPixels)
                guard !Task.isCancelled, heroGame?.id == game.id else { return }
                if let online { heroIcon = (game.id, online) }
            }
        }
    }

    /// The question after the first start of an app nxkit built: it was played after the build nxkit recorded, and not asked yet.
    func nxkitLaunchPrompt(_ game: LibraryGame) -> NxkitFeedbackPrompt? {
        guard let record = m.nxkitRecord(game.titleID), let played = game.lastPlayed, played >= record.date,
              !m.nxkitFeedbackAsked(record.buildID + "." + NxkitFeedbackPrompt.Moment.firstLaunch.rawValue),
              let app = game.playableMacBundle, app.upstream == .nxkit else { return nil }
        return NxkitFeedbackPrompt(buildID: record.buildID, moment: .firstLaunch, titleID: game.titleID, gameName: game.displayName(loc.lang),
                                   gameVersion: app.version ?? "", nxkitVersion: record.version, engineBuild: record.hostBuild,
                                   appPath: game.appPath, since: record.date)
    }

    /// An app nxkit built without a game profile (NxkitBuildProfile), and its prefilled report: only what this launcher knows.
    /// Runtime logs are collected lazily when the player clicks Report.
    func nxkitGenericBuild(_ game: LibraryGame) -> (profile: NxkitBuildProfile, makeReport: () -> URL)? {
        guard let app = game.playableMacBundle, app.upstream == .nxkit, let profile = NxkitBuildProfile.read(app: game.appPath) else { return nil }
        let title = game.displayName(loc.lang)
        let titleID = game.titleID
        let gameVersion = app.version ?? ""
        let record = m.nxkitRecord(game.titleID)
        let nxkitVersion = profile.nxkitVersion ?? record?.version ?? ""
        let appPath = game.appPath
        let since = record?.date
        return (profile, {
            let runtimeLog = NxkitRuntimeLog.collect(titleID: titleID, appPath: appPath, since: since)
            return NxkitFeedback.genericBuildReportURL(gameName: title, titleID: titleID, gameVersion: gameVersion,
                                                       nxkitVersion: nxkitVersion, log: runtimeLog)
        })
    }

    private func heroBadges(_ game: LibraryGame) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { heroBadgeContent(game) }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { heroBadgeContent(game) }
        }
    }

    @ViewBuilder private func heroBadgeContent(_ game: LibraryGame) -> some View {
        Group {
            LibraryArtworkChip(state: library.artworkState(for: game, building: isBuildingGame(game), queued: isQueuedGame(game)))
            libraryMetadataBadges(game)
        }
    }

    /// Narrow windows place collection controls on a separate line.
    static let collectionWideHeaderWidth: CGFloat = 1100

    /// The All games grid (LauncherView+Carousel.swift opens it): the whole library, filtered, ordered and counted.
    func collection(width: CGFloat) -> some View {
        let cardWidth = LibraryCardLayout.width(in: width)
        let columns = LibraryCardLayout.columns(in: width)
        let games = filteredGames
        let heroID = heroGame?.id
        let compactHeader = width < Self.collectionWideHeaderWidth
        return VStack(alignment: .leading, spacing: 18) {
            let headerLayout = compactHeader
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 16))
            headerLayout {
                allGamesHeader(count: games.count, compact: compactHeader)
                HStack(spacing: 12) {
                Spacer(minLength: 0)
                LauncherGlassGroup {
                    HStack(spacing: 12) {
                        if !library.games.isEmpty { collectionBatchRefreshButton(compact: compactHeader) }
                        activityLogButton()
                        Button(loc.t("supported.title"), action: openSupportedGames)
                            .buttonStyle(LauncherSecondaryButtonStyle())
                            .padTarget("library.supported", scope: "main", activate: openSupportedGames)
                        HStack(spacing: 8) {
                            // a narrow window keeps the menu without the word before it (the menu's accessible label says Sort)
                            if !compactHeader { Text(loc.t("sort.label")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize() }
                            LauncherDropdown(options: LibrarySort.allCases.map { ($0.rawValue, loc.t($0.labelKey)) }, selection: librarySort.rawValue,
                                             label: loc.t("sort.label"), style: .button) { setLibrarySort(LibrarySort(rawValue: $0) ?? .recent) }
                                .padTarget("library.sort", scope: "main",
                                           activate: { setLibrarySort(librarySort == .recent ? .name : .recent) },
                                           adjust: { setLibrarySort($0 > 0 ? .name : .recent) })
                        }
                        LauncherSegmented(options: LibraryFilter.libraryOptions.map { ($0.rawValue, loc.t($0.labelKey)) },
                                          selection: libraryFilter.rawValue) { setLibraryFilter(LibraryFilter(rawValue: $0) ?? .owned) }
                            .compactFrame(minWidth: LauncherControl.width)
                            .padTarget("library.filter", scope: "main",
                                       activate: { setLibraryFilter(libraryFilter == .ios ? .owned : libraryFilter.adjusted(1)) },
                                       adjust: { setLibraryFilter(libraryFilter.adjusted($0)) })
                    }
                }
                }
            }.id("library.collection.header")
            if games.isEmpty && !library.games.isEmpty {
                Text(loc.t(search.isEmpty ? "console.allGames.empty" : "library.noResults"))
                    .font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
            } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: LibraryCardLayout.gridSpacing, alignment: .top), count: columns),
                      alignment: .leading, spacing: 18) {
                if games.isEmpty {
                    ForEach(0..<(columns * 2), id: \.self) { _ in LibraryCarouselPlaceholder(width: cardWidth) }
                } else {
                    ForEach(games) { game in
                        let _ = LauncherWork.count(.card)
                        collectionCard(game, width: cardWidth, selected: game.id == heroID, in: games, columns: columns,
                                       choose: { chooseFromAllGames(game) })
                    }
                }
            }.padding(.top, 8)
            }
        }
        .padding(.horizontal, 34).padding(.top, 8).padding(.bottom, 22)
    }

    static func tunedMetadataBadge(for game: LibraryGame, t: (String) -> String) -> LibraryGameCard.TunedBadge? {
        LibraryGameCard.tunedBadge(
            built: game.playableMacBundle?.upstream,
            builtUpstreams: game.sortedMacBuilds.map(\.upstream),
            available: EngineUpstream.tunedEngines(forTitleID: game.titleID),
            t: t
        )
    }

    var queuedLibraryTitleIDs: Set<String> {
        Set(buildQueue.queued.map { $0.titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() })
    }

    func isBuildingGame(_ game: LibraryGame) -> Bool {
        guard m.running else { return false }
        if activeBuildID == game.id { return true }
        if let running = buildQueue.running, running.titleID.caseInsensitiveCompare(game.titleID) == .orderedSame { return true }
        if m.buildingGame, let buildingTitleID = m.gameTitleID, !buildingTitleID.isEmpty,
           buildingTitleID.caseInsensitiveCompare(game.titleID) == .orderedSame { return true }
        return false
    }

    func isQueuedGame(_ game: LibraryGame) -> Bool {
        !isBuildingGame(game) && buildQueue.queued.contains { $0.titleID.caseInsensitiveCompare(game.titleID) == .orderedSame }
    }

    func effectiveLibraryQueueTarget(for game: LibraryGame, selectedTarget: String? = nil, upstream: EngineUpstreamKind? = nil, supportsGenericNUP: Bool? = nil) -> String {
        let baseTarget = selectedTarget ?? (m.isMacOnlyUpstreamSelected ? BuildTarget.mac : BuildTarget.normalized(m.target))
        let resolvedUpstream = resolvedLibraryQueueUpstream(for: game, selectedTarget: baseTarget, activeUpstream: upstream ?? m.buildUpstream, supportsGenericNUP: supportsGenericNUP ?? MacNativeGamesBuilder.supportsGenericNUP(in: m.macNativeGamesPath))
        return resolvedUpstream.buildsMacOnly ? BuildTarget.mac : baseTarget
    }

    private func resolvedLibraryQueueUpstream(for game: LibraryGame, selectedTarget: String, activeUpstream: EngineUpstreamKind, supportsGenericNUP: Bool) -> EngineUpstreamKind {
        let isNUP = MacNativeGamesBuilder.isNUPInputPath(game.inputs[GameLibrary.folderInput]?.first)
            || MacNativeGamesBuilder.isNUPInputPath(game.inputs["base"]?.first)
        return BuildSelectedSheet.rowEngineTag(
            for: game.titleID,
            selectedTarget: selectedTarget,
            activeUpstream: activeUpstream,
            isNUP: isNUP,
            supportsGenericNUP: supportsGenericNUP
        ) ?? activeUpstream
    }

    /// Adds games to the build queue with the Builds page's target, upstream, and iOS delivery settings (#1112).
    func enqueueBuilds(_ games: [LibraryGame]) {
        let batch = UUID()
        let upstream = m.buildUpstream
        let selectedTarget = m.isMacOnlyUpstreamSelected ? BuildTarget.mac : BuildTarget.normalized(m.target)
        let packagesSharedApp = !(devices.exportIPA && (devices.exportOneGame || devices.exportFramework))
        let exportsFramework = devices.exportIPA && !devices.exportOneGame && devices.exportFramework
        let supportsGenericNUP = MacNativeGamesBuilder.supportsGenericNUP(in: m.macNativeGamesPath)
        let entries = games.compactMap { game -> QueueEntry? in
            guard !isBuildingGame(game), game.hasQueueableSources else { return nil }
            let rowUpstream = resolvedLibraryQueueUpstream(for: game, selectedTarget: selectedTarget, activeUpstream: upstream, supportsGenericNUP: supportsGenericNUP)
            let effectiveTarget = rowUpstream.buildsMacOnly ? BuildTarget.mac : selectedTarget
            guard buildQueue.canEnqueue(game.titleID, target: effectiveTarget) else { return nil }
            let isIOS = effectiveTarget != BuildTarget.mac
            let standaloneIOS = isIOS && rowUpstream.buildsIOSStandaloneOnly
            return QueueEntry(
                game: game,
                engineID: stores.engineSync.selection.engineID,
                target: effectiveTarget,
                batch: batch,
                packageAfter: !standaloneIOS && packagesSharedApp && isIOS,
                exportIPA: standaloneIOS ? true : (isIOS && exportsFramework ? true : nil),
                exportFramework: standaloneIOS ? false : (isIOS && exportsFramework ? true : nil),
                autoFetchCheats: m.autoFetchCheats,
                separateRomfs: (standaloneIOS && rowUpstream == .kidWithSword) ? m.kwsSeparateRomfs : nil
            )
        }
        buildQueue.enqueue(entries)
    }

    func libraryMetadataBadges(_ game: LibraryGame) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) { metadataBadgeContent(game) }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { metadataBadgeContent(game) }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func metadataBadgeContent(_ game: LibraryGame) -> some View {
        Group {
            if let played = heroPlayTime(for: game) {
                DSTag(played)
                    .help(loc.t("activity.totalTime"))
                    .accessibilityLabel("\(loc.t("activity.totalTime")) \(played)")
            }
            if let badge = Self.tunedMetadataBadge(for: game, t: { loc.t($0) }) {
                DSTag(badge.title, emphasized: true, width: badge.fixedWidth)
                    .help(badge.help)
                    .accessibilityLabel(badge.help)
            }
            if game.playableMacBundle?.upstream == .nxkit, NxkitBuildProfile.read(app: game.appPath) != nil {
                // built without a game profile (v0lumehi/nxkit#54): a quiet tag, the row under the actions says what it means
                DSTag(loc.t("nxkit.generic.badge"), emphasized: true)
                    .help(loc.t("nxkit.generic.help"))
                    .accessibilityLabel(loc.t("nxkit.generic.help"))
                    .accessibilityIdentifier("hero.nxkitGeneric")
            }
            if GameFolder.profileIsSwitch2(game.titleID, engineRoot: EngineLayout.root(m.repo.path)) {   // #445
                ArtworkStatusChip(title: loc.t("switch2.badge"), color: LauncherPalette.notice, showsIndicator: false)
                    .help(loc.t("switch2.help"))
            }
            if verifiedProfiles.isUnverified(game) {
                LibraryProfileChip(title: loc.t("macLibVerify.badge"), explanation: loc.t("macLibVerify.note"), showingHelp: $profileHelpOpen).id(game.id)
            }
            if game.isOlderIOSBuild {
                ArtworkStatusChip(title: loc.t("library.chip.olderIOS"), color: LauncherPalette.advisory)
                    .help(loc.t("library.olderIOS"))
            }
            if toolsAge.older.contains(game.id) {   // a quiet note beside the status, not a warning
                ArtworkStatusChip(title: loc.t("library.olderToolsShort"), color: ArtworkStatusChip.neutralColor, showsIndicator: false)
                    .help(loc.t("library.olderToolsHelp"))
            }
            deviceFrameworkBadge(game)
        }
        .accessibilityElement(children: .contain)
    }

}
