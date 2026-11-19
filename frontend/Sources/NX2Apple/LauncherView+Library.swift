import SwiftUI
import CoreText
import NXCore
import NXModel
import NXLauncher

/// The Library page of the launcher: the hero, the collection grid and the status line of a game. A move out of LauncherView.swift
/// (LNPANDY/NX2Apple#387), the state stays in LauncherView.
extension LauncherView {
    private var libraryReservedHeaderHeight: CGFloat {
        if #available(macOS 26, *) { return 0 }
        return libraryHeaderHeight
    }

    var libraryPage: some View {
        GeometryReader { geometry in
            let editing = artworkEditor != nil
            let width = max(0, geometry.size.width - (editing ? ArtworkPanel.width + 1 : 0))
            ScrollViewReader { proxy in
            ScrollView {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        let full = CGSize(width: geometry.size.width,
                            height: editing ? closedHeroHeight : LibraryHeroLayout.height(
                                available: geometry.size.height - libraryReservedHeaderHeight - 274,
                                hasDeviceActions: library.games.contains { !$0.installedDevice.isEmpty }))
                        let scale = min(1, width / max(1, full.width))
                        hero(heroGame, width: full.width, height: full.height)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: width, height: editing ? full.height * scale : nil, alignment: .topLeading)
                            .opacity(dimmed(.hero))
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                                if !editing {
                                    closedHeroHeight = size.height
                                    artworkHeroAspect = size.width / max(1, size.height)
                                }
                            }
                        collection(width: width)
                            .opacity(dimmed(.thumbnail))
                    }.frame(width: width)
                    if editing { Color.clear.frame(width: ArtworkPanel.width + 1) }
                }
            }
            .onChange(of: padFocus.focused) { id in
                if let id, id.hasPrefix("card.") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(id) }
                } else if id == "library.sort" || id == "library.filter",
                          let id, let frame = padFocus.frame(of: id),
                          frame.minY < libraryHeaderHeight || frame.maxY > geometry.size.height {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("library.collection.header", anchor: .center) }
                }
            }
            .onChange(of: keyboardCard) { id in
                if let id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("card." + id.uuidString) } }
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
            .modifier(LibraryHeaderBar(header: VStack(spacing: 0) {
                topBar
                EngineSyncBanner(engine: stores.engineSync, m: m)
            }.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { libraryHeaderHeight = $0 }))
        }
    }

    func hero(_ game: LibraryGame?, width: CGFloat, height: CGFloat) -> some View {
        let lightHero = colorScheme == .light
        let layout = LibraryHeroLayout.content(width: width, height: height, headerHeight: libraryHeaderHeight)
        let titleSize = layout.titleSize
        let titleTopInset = Typography.manropeFont(size: titleSize, weight: .heavy).map { max(0, CTFontGetAscent($0) - CTFontGetCapHeight($0)) } ?? 0
        let iconSize = layout.iconSize
        let contentGap = layout.columnGap
        let textWidth = max(0, width - 68 - iconSize - contentGap)
        return ZStack(alignment: .bottomLeading) {
            GeometryReader { position in
                let pull = max(0, position.frame(in: .named("library.scroll")).minY)
                let backdropHeight = max(height, position.size.height)
                ZStack {
                    ZStack {
                        if let game, let image = heroImage(for: game) {
                            let state = library.artworkState(for: game, building: m.running && activeBuildID == game.id)
                            ArtworkFill(image: image, focus: displayed(game).artwork.focus(for: .hero))
                                .saturation(LibraryArtworkTone.saturation(muted: state.monochrome))
                                .blur(radius: 24, opaque: true)
                                .id(game.id).transition(.opacity)
                        } else {
                            LibraryFallbackArtwork(size: CGSize(width: width + 96, height: backdropHeight + pull + 96))
                        }
                    }
                    .animation(LibraryHeroTransition.artwork(reduceMotion: reduceMotion), value: game?.id)
                    .frame(width: width + 96, height: backdropHeight + pull + 96)
                    .frame(width: width, height: max(0, backdropHeight + pull - 1)).clipped()
                    .frame(width: width, height: backdropHeight + pull, alignment: .top)
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
                }.frame(width: width, height: backdropHeight + pull)
                .background(LauncherPalette.background)
                .offset(y: -pull)
            }.allowsHitTesting(false)
            Group {
                if let game {
                    HStack(alignment: .bottom, spacing: contentGap) {
                        ZStack {
                            Group {
                                if let icon = (heroIcon?.id == game.id ? heroIcon?.image : nil)
                                    ?? GameLibrary.appIcon(for: game, banners: library.artworkDirectory) {
                                    Image(nsImage: icon).resizable().scaledToFill()
                                } else {
                                    ZStack {
                                        LauncherPalette.surface
                                        Image(systemName: "gamecontroller").font(.system(size: iconSize * 0.3)).foregroundStyle(.secondary)
                                    }
                                }
                            }.id(game.id).transition(.opacity)
                        }
                        .animation(LibraryHeroTransition.metadata(reduceMotion: reduceMotion), value: game.id)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: iconSize / 12))
                        .accessibilityHidden(true)
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
                                        .shadow(color: lightHero ? .white.opacity(0.55) : .black.opacity(0.25), radius: 12)
                                        .frame(width: textWidth, alignment: .leading)
                                        .id(game.id).transition(.opacity)
                                }
                                .animation(LibraryHeroTransition.metadata(reduceMotion: reduceMotion), value: game.id)
                            }
                            heroActions(game, lightHero: lightHero, compact: width < 760)
                            if game.onDevice, let expiry = signatureExpiry[game.id], AppSignature.isUrgent(expiry) {
                                Label(AppSignature.describe(expiry, loc.t), systemImage: "exclamationmark.triangle.fill")
                                    .font(.manrope(12, .semibold)).foregroundStyle(LauncherPalette.building)
                                    .fixedSize(horizontal: false, vertical: true)
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
                                Text(loc.t("library.switch2Content")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)   // #1057
                            }
                            if let resignNote {
                                Text(resignNote).font(.manrope(12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
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

    private func heroBadges(_ game: LibraryGame) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { heroBadgeContent(game) }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { heroBadgeContent(game) }
        }
    }

    @ViewBuilder private func heroBadgeContent(_ game: LibraryGame) -> some View {
        Group {
            LibraryArtworkChip(state: library.artworkState(for: game, building: m.running && activeBuildID == game.id))
            libraryMetadataBadges(game)
        }
    }

    /// Narrow windows place collection controls on a separate line.
    static let collectionWideHeaderWidth: CGFloat = 1100

    func collection(width: CGFloat) -> some View {
        let cardWidth = LibraryCardLayout.width(in: width)
        let columns = LibraryCardLayout.columns(in: width)
        let games = filteredGames
        let heroID = heroGame?.id
        return VStack(alignment: .leading, spacing: 18) {
            let headerLayout = width < Self.collectionWideHeaderWidth
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 16))
            headerLayout {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(loc.t("library.yourLibrary")).font(.manrope(28, .bold)).tracking(-0.6).fixedSize()
                    Text("(" + String(format: loc.t("library.gameCount"), games.count) + ")").font(.manrope(12)).foregroundStyle(.secondary)
                    Button(loc.t("supported.title"), action: openSupportedGames)
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .padTarget("library.supported", scope: "main", activate: openSupportedGames)
                }
                HStack(spacing: 12) {
                Spacer(minLength: 0)
                let compactHeader = width < Self.collectionWideHeaderWidth
                if !library.games.isEmpty {
                    collectionBatchRefreshButton(compact: compactHeader)
                }
                HStack(spacing: 8) {
                    // a narrow window keeps the menu without the word before it (the menu's accessible label says Sort)
                    if !compactHeader { Text(loc.t("sort.label")).font(.manrope(12)).foregroundStyle(.secondary).fixedSize() }
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
            }.id("library.collection.header")
            if library.showsSkippedBanner {
                LibrarySkippedBanner(
                    items: library.skippedItems,
                    enabled: artworkEditor == nil,
                    openDetails: { skippedItemsOpen = true },
                    dismiss: { library.dismissSkippedBanner() }
                )
            }
            if games.isEmpty && !library.games.isEmpty {
                Text(loc.t(search.isEmpty ? "console.allGames.empty" : "library.noResults"))
                    .font(.manrope(17)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
            } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: LibraryCardLayout.gridSpacing, alignment: .top), count: columns),
                      alignment: .leading, spacing: 18) {
                if games.isEmpty {
                    ForEach(0..<(columns * 2), id: \.self) { _ in LibraryCarouselPlaceholder(width: cardWidth) }
                } else {
                    ForEach(games) { game in
                        let _ = LauncherWork.count(.card)
                        collectionCard(game, width: cardWidth, selected: game.id == heroID, columns: columns)
                    }
                }
            }.padding(.top, 8)
            }
        }
        .padding(.horizontal, 34).padding(.top, 8).padding(.bottom, 22)
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
            if GameFolder.profileIsSwitch2(game.titleID, engineRoot: EngineLayout.root(m.repo.path)) {   // #445
                ArtworkStatusChip(title: loc.t("switch2.badge"), color: LauncherPalette.notice, showsIndicator: false)
                    .help(loc.t("switch2.help"))
            }
            if verifiedProfiles.supportsFullScreen(game) {
                ArtworkStatusChip(title: loc.t("widescreen.badge"), color: LauncherPalette.ready, textColor: .white)
                    .help(loc.t("widescreen.help"))
            }
            if verifiedProfiles.isUnverified(game) {
                LibraryProfileChip(title: loc.t("macLibVerify.badge"), explanation: loc.t("macLibVerify.note"), showingHelp: $profileHelpOpen).id(game.id)
            }
            if game.isOlderIOSBuild {
                ArtworkStatusChip(title: loc.t("library.chip.olderIOS"), color: LauncherPalette.advisory, textColor: .white)
                    .help(loc.t("library.olderIOS"))
            }
            if toolsAge.older.contains(game.id) {   // a quiet note beside the status, not a warning
                ArtworkStatusChip(title: loc.t("library.olderToolsShort"), color: ArtworkStatusChip.neutralColor, showsIndicator: false)
                    .help(loc.t("library.olderToolsHelp"))
            }
        }
        .accessibilityElement(children: .contain)
    }

}
