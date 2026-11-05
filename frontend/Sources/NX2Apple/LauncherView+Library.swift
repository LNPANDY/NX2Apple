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
                            hero(game, width: geometry.size.width, height: max(240, geometry.size.height - collectionHeight))
                        }
                        // The hero takes what the collection leaves: the row's height grows with the window's width (its cards
                        // do, up to 300 pt), so a fixed share left a fullscreen window's cards cut off at the bottom
                        collection(width: geometry.size.width)
                            .background(GeometryReader { g in Color.clear.preference(key: CollectionHeightKey.self, value: g.size.height) })
                    }
                }
                .onPreferenceChange(CollectionHeightKey.self) { h in if h > 0, abs(h - collectionHeight) > 0.5 { collectionHeight = h } }
            }
        }
    }

    var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 22) {
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
                    .foregroundStyle(.black).background(LauncherPalette.cream, in: Capsule())
            }
            .buttonStyle(.plain).padding(.top, 8)
            Button(action: chooseLibraryFolder) {
                Label(loc.t("library.chooseFolder"), systemImage: "folder")
                    .font(.manrope(14)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            Spacer()
            Text(loc.t("library.localNote")).font(.manrope(12)).foregroundStyle(.secondary)
        }
        .padding(48).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    func hero(_ game: LibraryGame, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let image = heroArtwork?.id == game.id ? heroArtwork?.image : artwork[game.id] {
                ArtworkFill(image: image, focus: game.artwork.focus(for: .hero))
                    .frame(width: width, height: height).clipped()
            } else {
                LauncherPalette.surface
                Image(systemName: "gamecontroller").font(.system(size: 160, weight: .ultraLight))
                    .foregroundStyle(Color.white.opacity(0.05))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(60)
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.25),
                                   .init(color: .black.opacity(0.25), location: 0.45),
                                   .init(color: LauncherPalette.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.24), .clear], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    status(game, prominent: true)
                    if toolsAge.older.contains(game.id) && !(m.running && activeBuildID == game.id) {
                        Button { configureBuild(game) } label: {
                            Label(loc.t("library.rebuildShort"), systemImage: "arrow.clockwise")
                                .font(.manrope(12, .semibold)).foregroundStyle(LauncherPalette.cream)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .overlay(Capsule().strokeBorder(LauncherPalette.cream.opacity(0.35)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).disabled(m.running || game.inputs["base", default: []].isEmpty)
                        .help(loc.t("library.olderToolsHelp"))
                        .padTarget("hero.rebuild", scope: "main", radius: 12) { if !m.running { configureBuild(game) } }
                    }
                }
                Text(game.name).font(.manrope(min(68, width * 0.052), .heavy))
                    .tracking(-1.6).lineLimit(2).shadow(color: .black.opacity(0.25), radius: 12)
                HStack(spacing: 18) {
                    Button { primaryAction(game) } label: {
                        LauncherHeroActionLabel(
                            title: game.primary == .play ? loc.t("library.play")
                                : (game.primary == .openOnDevice ? String(format: loc.t("dev.open"), devices.deviceName(game.installedDevice))
                                   : loc.t("library.newBuild")),
                            symbol: game.primary == .play ? "play.fill" : (game.primary == .openOnDevice ? "iphone" : "hammer.fill"))
                    }
                    .buttonStyle(.plain).disabled(launching || (m.running && !game.isReady))
                    .keyboardShortcut(.return, modifiers: [])
                    .padTarget("hero.play", scope: "main", radius: 30) { if !launching { primaryAction(game) } }
                    if game.isReady {
                        Button { optionsFor = game.id } label: {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 17))
                                .frame(width: 48, height: 48)
                                .background(Color.white.opacity(0.10), in: Circle())
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.14)))
                        }
                        .buttonStyle(.plain).help(loc.t("launch.title")).accessibilityLabel(loc.t("launch.title"))
                        .padTarget("hero.options", scope: "main", radius: 24) { optionsFor = game.id }
                    }
                    Button { manageOpenFor = manageOpenFor == nil ? game.id : nil } label: { ManageButtonLabel(title: loc.t("library.manage")) }
                        .buttonStyle(.plain).accessibilityLabel(loc.t("library.manage"))
                        .anchorPreference(key: ManageAnchorKey.self, value: .bounds) { $0 }
                        .padTarget("hero.manage", scope: "main", radius: 12) { manageOpenFor = game.id }
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
                        .buttonStyle(.plain).disabled(m.running)
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

    func collection(width: CGFloat) -> some View {
        let cardWidth = min(300, max(190, (width - 124) / 5))
        let step = cardWidth + 14
        let games = filteredGames
        let heroID = heroGame?.id
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Text(loc.t("library.collection")).font(.manrope(28, .bold)).tracking(-0.6)
                Spacer()
                LauncherSegmented(options: LibraryFilter.allCases.map { ($0.rawValue, loc.t($0.labelKey)) },
                                  selection: libraryFilter.rawValue) { setLibraryFilter(LibraryFilter(rawValue: $0) ?? .owned) }
                    .frame(width: LauncherControl.width)
                    .padTarget("library.filter", scope: "main", radius: 17,
                               activate: { setLibraryFilter(libraryFilter == .owned ? .built : .owned) },
                               adjust: { setLibraryFilter($0 > 0 ? .built : .owned) })
                Text(String(format: loc.t("library.gameCount"), libraryFilter == .owned ? library.games.count : library.games.filter(libraryFilter.includes).count))
                    .font(.manrope(12)).foregroundStyle(.secondary)
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
                                                ArtworkFill(image: image, focus: game.artwork.focus(for: .thumbnail))
                                            } else {
                                                LauncherPalette.surface
                                                Image(systemName: "gamecontroller").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(width: cardWidth, height: cardWidth / 1.8).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                                            game.id == heroID ? LauncherPalette.cream : .clear, lineWidth: 2))
                                        Text(game.name).font(.manrope(16, .semibold)).lineLimit(1)
                                        status(game)
                                        Capsule().fill(game.id == heroID ? LauncherPalette.cream : .clear)
                                            .frame(height: 3).padding(.top, 4)
                                    }
                                    .frame(width: cardWidth, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
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
        .buttonStyle(.plain)
        .frame(height: height)
        .accessibilityLabel(loc.t(symbol == "chevron.left" ? "library.scrollBack" : "library.scrollForward"))
        .transition(.opacity)
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
                    .font(.manrope(prominent ? 11 : 10.5, .bold)).foregroundStyle(LauncherPalette.cream.opacity(0.85))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(LauncherPalette.cream.opacity(0.35)))
                    .help(loc.t("switch2.help"))
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
