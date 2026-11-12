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
                                .onAppear { closedHeroHeight = full.height; artworkHeroAspect = full.width / full.height }
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
                HStack(spacing: 10) {
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
                    if toolsAge.older.contains(game.id) && !(m.running && activeBuildID == game.id) {
                        // Never started by itself: the player adds the game, or every game built with older tools, to the build queue (#944)
                        heroRebuildButton(loc.t("library.rebuildShort"), id: "hero.rebuild", games: [game], frosted: lightHero)
                        let others = olderToolsGames
                        if others.count > 1 {
                            heroRebuildButton(String(format: loc.t("library.rebuildAll"), others.count), id: "hero.rebuildAll", games: others, frosted: lightHero)
                        }
                    }
                }
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
                if toolsAge.older.contains(game.id) && !(m.running && activeBuildID == game.id) {
                    Text(loc.t("library.olderToolsSafeNote"))
                        .font(.manrope(12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if game.switch2EditionContentFound, !GameFolder.profileIsSwitch2(game.titleID, engineRoot: EngineLayout.root(m.repo.path)) {
                    Text(loc.t("library.switch2Content")).font(.manrope(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)   // #1057
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
                    .onChange(of: padFocus.focused) { id in   // the focused card scrolls into the row's view
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

    /// An outlined pill that adds games to the build queue: one game, or all that were built with older tools. It starts nothing itself.
    func heroRebuildButton(_ title: String, id: String, games: [LibraryGame], frosted: Bool = false) -> some View {
        let add = {
            guard !m.running else { return }
            let batch = UUID()
            stores.queue.enqueue(games.map {
                QueueEntry(game: $0, engineID: stores.engineSync.selection.engineID, target: m.target, batch: batch,
                           packageAfter: m.target != BuildTarget.mac && !m.exportsOneGame)
            })
            page = .builds
        }
        return Button(action: add) {
            Label(title, systemImage: "arrow.clockwise")
                .font(.manrope(12, .semibold)).foregroundStyle(LauncherPalette.cream)
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
        .buttonStyle(.plain).launcherHover(enabled: artworkEditor == nil).disabled(m.running || games.isEmpty)
        .help(loc.t("library.olderToolsHelp"))
        .padTarget(id, scope: "main", radius: 12, activate: add)
    }

    func status(_ game: LibraryGame, prominent: Bool = false) -> some View {
        let building = m.running && activeBuildID == game.id
        let color = building ? LauncherPalette.building : ((game.isReady || game.hasIOSBuild) ? LauncherPalette.ready : LauncherPalette.unbuilt)
        let key = building ? "library.building" : (game.isReady ? "library.ready" : (game.hasIOSBuild ? (game.isOlderIOSBuild ? "library.olderIOS" : "library.readyIOS") : "library.notBuilt"))
        return HStack(spacing: 7) {
            Circle().fill(color).frame(width: prominent ? 9 : 7, height: prominent ? 9 : 7)
            Text(prominent ? loc.t(key).uppercased() : loc.t(key))
                .font(prominent ? .manrope(12, .bold) : .manrope(13, .medium))
                .tracking(prominent ? 1.3 : 0)   // the eyebrow: the same face, in tracked capitals
                .foregroundStyle(color)
            if GameFolder.profileIsSwitch2(game.titleID, engineRoot: EngineLayout.root(m.repo.path)) {   // #445
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
            if !building && toolsAge.older.contains(game.id) {   // a quiet note beside the status, not a warning
                Text("· " + loc.t(prominent ? "library.olderTools" : "library.olderToolsShort"))
                    .font(.manrope(prominent ? 13 : 12)).foregroundStyle(.secondary).lineLimit(1)
                    .help(loc.t("library.olderToolsHelp"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
