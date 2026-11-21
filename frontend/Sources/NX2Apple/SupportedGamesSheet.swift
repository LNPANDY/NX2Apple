import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Library > Supported games… (LNPANDY/NX2Apple#301): every game the shipped engine has a profile for, searchable, apart from what the
/// player owns. Only the profile's own words: the version it was brought up on, its notes. No download or buy action, no status the
/// profile does not state. Each row shows the game's cover, the library's own (SupportedCovers), fetched while the row is on screen.
struct SupportedGamesSheet: View {
    let games: [SupportedGame]
    /// The library's game for a title ID, else nil: the row says whether the player has it, and offers to show it.
    let owned: (String) -> LibraryGame?
    @StateObject private var covers: SupportedCovers
    let showInLibrary: (UUID) -> Void
    /// The owned game's build is older than the tools: a profile improved in this release needs a rebuild to apply.
    let olderBuild: (UUID) -> Bool
    /// Opens the game's build (the Builds page with its form), after the sheet closes.
    let rebuild: (UUID) -> Void
    let appVersion: String
    /// Whether a profile was improved in this release (GameUpdateCatalog), replaced by the state gallery's stand-ins.
    let improved: ((String) -> Bool)?
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.dismiss) private var dismiss
    /// Filter scope for the supported games list.
    enum UpstreamFilter: String, Equatable {
        case all
        case macNativeGames
    }

    @State private var search = ""
    @State private var upstreamFilter: UpstreamFilter
    @State private var selected: String?
    @FocusState private var searchFocused: Bool

    /// The cover in the 40 pt square slot of a list (DS.Control.thumbnail): the banner's middle, decoded high enough at 2x.
    static let coverPixels = 160

    init(games: [SupportedGame], owned: @escaping (String) -> LibraryGame?, covers: @escaping @autoclosure () -> SupportedCovers,
         showInLibrary: @escaping (UUID) -> Void, olderBuild: @escaping (UUID) -> Bool = { _ in false }, rebuild: @escaping (UUID) -> Void = { _ in },
         appVersion: String = AppUpdateStore.appVersion, improved: ((String) -> Bool)? = nil, expanded: String? = nil,
         initialFilter: UpstreamFilter = .all) {
        _upstreamFilter = State(initialValue: initialFilter)
        _selected = State(initialValue: expanded)   // visual QA: a row with its notes open
        self.games = games
        self.owned = owned
        _covers = StateObject(wrappedValue: covers())
        self.showInLibrary = showInLibrary
        self.olderBuild = olderBuild
        self.rebuild = rebuild
        self.appVersion = appVersion
        self.improved = improved
    }

    /// At most 720 tall and 80 shorter than the screen.
    static func height(screen: CGFloat) -> CGFloat { LauncherSheet.maxHeight(screen: screen) }

    static func isUpdatedInCurrentRelease(titleID: String, appVersion: String = AppUpdateStore.appVersion) -> Bool {
        GameUpdateCatalog.catalogVersion(for: titleID) == GameUpdateCatalog.releaseBaseVersion(appVersion)
    }

    /// One of the titles MacNativeGames maintains (and MacNativeGames is offered at all).
    static func isMacNativeGamesSupported(_ game: SupportedGame) -> Bool {
        MacNativeGamesBuilder.featureEnabled && MacNativeGamesBuilder.supportsTitleID(game.titleID)
    }

    /// The release as the tag says it: "1.5" for 1.5.0, a patch release in full.
    static func shortVersion(_ version: String) -> String {
        let parts = version.split(separator: ".")
        return parts.count == 3 && parts[2] == "0" ? parts.prefix(2).joined(separator: ".") : version
    }

    /// The tag of a profile improved in this release ("Improved in 1.5"), nil for one that was not.
    static func improvedTag(for titleID: String, appVersion: String = AppUpdateStore.appVersion, t: (String) -> String) -> String? {
        guard isUpdatedInCurrentRelease(titleID: titleID, appVersion: appVersion) else { return nil }
        return String(format: t("supported.improvedIn"), shortVersion(GameUpdateCatalog.releaseBaseVersion(appVersion)))
    }

    /// The search finds a game by its name, title ID, the owned game's name, the release its profile was improved in, and by the
    /// words of its Improved tag (in `improvedName`, else in every language).
    static func matchesSearch(_ game: SupportedGame, needle: String, ownedName: String, improvedName: String = "",
                              appVersion: String = AppUpdateStore.appVersion) -> Bool {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let updated = GameUpdateCatalog.catalogVersion(for: game.titleID) ?? ""
        var fields = [game.name, game.titleID, ownedName, updated]
        if isUpdatedInCurrentRelease(titleID: game.titleID, appVersion: appVersion) {
            if improvedName.isEmpty {
                fields.append(contentsOf: Lang.all.compactMap { lang in improvedTag(for: game.titleID, appVersion: appVersion, t: { L10n.string($0, lang) }) })
            } else {
                fields.append(improvedName)
            }
        }
        if isMacNativeGamesSupported(game) {   // "MacNativeGames" or "MNG" finds the titles it maintains
            fields.append(EngineUpstreamKind.macNativeGames.displayName)
            fields.append("MNG")
        }
        return fields.contains {
            $0.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The subtitle: the edition, the game version the profile was made with (or the MacNativeGames engine note for
    /// MacNativeGames-only entries without a profile version), and the release that last changed the profile unless it is this one.
    static func detailText(for game: SupportedGame, appVersion: String = AppUpdateStore.appVersion, t: (String) -> String) -> String {
        var parts: [String] = []
        if game.edition == .switch2 { parts.append(t("switch2.badge")) }
        if let version = game.version {
            parts.append(String(format: t("supported.version"), version))
        } else if isMacNativeGamesSupported(game) {
            parts.append(t("upstream.mngCardNote"))
        } else {
            parts.append(t("supported.noVersion"))
        }
        if let updated = GameUpdateCatalog.catalogVersion(for: game.titleID), !isUpdatedInCurrentRelease(titleID: game.titleID, appVersion: appVersion) {
            parts.append(String(format: t("supported.lastUpdated"), updated))
        }
        return parts.joined(separator: " · ")
    }

    /// Filters supported games by upstream scope and search query.
    static func filterGames(_ games: [SupportedGame], upstreamFilter: UpstreamFilter, needle: String,
                            ownedName: (SupportedGame) -> String, improvedName: (SupportedGame) -> String,
                            appVersion: String = AppUpdateStore.appVersion) -> [SupportedGame] {
        games.filter { game in
            if upstreamFilter == .macNativeGames && !isMacNativeGamesSupported(game) { return false }
            return matchesSearch(game, needle: needle, ownedName: ownedName(game),
                                 improvedName: improvedName(game), appVersion: appVersion)
        }
    }

    var macNativeGamesCount: Int {
        games.filter(Self.isMacNativeGamesSupported).count
    }

    var hasMacNativeGames: Bool {
        MacNativeGamesBuilder.featureEnabled && macNativeGamesCount > 0
    }

    var shown: [SupportedGame] {
        Self.filterGames(games, upstreamFilter: hasMacNativeGames ? upstreamFilter : .all, needle: search,
                         ownedName: { owned($0.titleID)?.displayName(loc.lang) ?? "" },
                         improvedName: { improvedTag($0) ?? "" }, appVersion: appVersion)
    }

    /// This row's Improved tag.
    func improvedTag(_ game: SupportedGame) -> String? {
        guard let improved else { return Self.improvedTag(for: game.titleID, appVersion: appVersion, t: { loc.t($0) }) }
        return improved(game.titleID) ? String(format: loc.t("supported.improvedIn"), Self.shortVersion(GameUpdateCatalog.releaseBaseVersion(appVersion))) : nil
    }

    func detail(_ game: SupportedGame) -> String {
        Self.detailText(for: game, appVersion: appVersion, t: { loc.t($0) })
    }

    private var upstreamFilterControl: some View {
        let allLabel = loc.t("console.filter.all")
        let mngLabel = "\(EngineUpstreamKind.macNativeGames.displayName) (\(macNativeGamesCount))"
        return LauncherSegmented(
            options: [
                (UpstreamFilter.all.rawValue, allLabel),
                (UpstreamFilter.macNativeGames.rawValue, mngLabel)
            ],
            selection: upstreamFilter.rawValue
        ) { value in
            upstreamFilter = UpstreamFilter(rawValue: value) ?? .all
        }
        .compactFrame(minWidth: 260)
        .padTarget(
            "supported.filter",
            scope: "supported",
            activate: { upstreamFilter = upstreamFilter == .all ? .macNativeGames : .all },
            adjust: { upstreamFilter = $0 > 0 ? .macNativeGames : .all }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc.t("engine.title"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DSSheetInsets.gap) {
                DSSheetHeader(title: loc.t("supported.title"))
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.symbolDefault)
                    TextField(loc.t("supported.search"), text: $search).textFieldStyle(.plain).font(DS.Font.body)
                        .focused($searchFocused).accessibilityLabel(loc.t("supported.search"))
                }
                .padding(.horizontal, DS.Space.s).frame(height: DS.Control.height)
                .background(DS.Color.surfaceRaised, in: Capsule())
                .overlay(DSPill().strokeBorder(searchFocused ? DS.Color.accent : DS.Color.separator))
                if hasMacNativeGames {
                    upstreamFilterControl
                }
            }
            .padding(.horizontal, DSSheetInsets.horizontal).padding(.top, DSSheetInsets.vertical).padding(.bottom, DSSheetInsets.gap)
            DS.Color.separator.frame(height: 1)   // the top edge of the full-width list
            if shown.isEmpty {
                Text(loc.t("supported.none")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                 ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { game in
                            let mine = owned(game.titleID)
                            let improved = improvedTag(game)
                            SupportedGameRow(game: game, detail: detail(game), improved: improved,
                                             needsRebuild: improved != nil && mine.map { olderBuild($0.id) } == true,
                                             owned: mine, cover: covers.image(game.titleID),
                                             rebuild: { id in dismiss(); rebuild(id) },
                                             expanded: selected == game.titleID,
                                             toggle: { selected = selected == game.titleID ? nil : game.titleID },
                                             show: { id in showInLibrary(id); dismiss() }, move: { direction in
                                guard let index = shown.firstIndex(where: { $0.titleID == game.titleID }), shown.indices.contains(index + direction) else { return false }
                                let id = "supported.row." + shown[index + direction].titleID
                                proxy.scrollTo(id, anchor: .center)
                                focus.focused = id
                                return true
                            })
                                .onAppear { covers.appear(game.titleID) }
                                .onDisappear { covers.disappear(game.titleID) }
                            DS.Color.separator.frame(height: 1).padding(.leading, DSSheetInsets.horizontal)
                        }
                    }
                 }
                 .onChange(of: focus.focused) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            DSSheetButtonRow {
                Text(String(format: loc.t("supported.count"), shown.count)).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
            } buttons: {
                Button { dismiss() } label: { Text(loc.t("free.done")).font(DS.Font.bodyStrong).padding(.horizontal, DS.Space.m) }
                    .buttonStyle(DSPrimaryButtonStyle()).keyboardShortcut(.cancelAction)   // Escape closes, Return stays with the search
                    .padTarget("supported.close", scope: "supported", focusColor: DS.Color.accentOn) { dismiss() }
            }
            .padding(.horizontal, DSSheetInsets.horizontal).padding(.top, DSSheetInsets.gap).padding(.bottom, DSSheetInsets.vertical)
        }
        .background(Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true))   // Cmd+F, as in the library: the search of this list
        .padScope("supported", focus)
        .frame(width: 680)
        .frame(maxHeight: Self.height(screen: NSScreen.main?.visibleFrame.height ?? 800))
        .dsSheetSurface()
        .onChange(of: upstreamFilter) { _ in
            if let current = selected, !shown.contains(where: { $0.titleID == current }) {
                selected = nil
            }
            if let id = focus.focused, id.hasPrefix("supported.row."), !shown.contains(where: { "supported.row." + $0.titleID == id }) {
                focus.focused = shown.first.map { "supported.row." + $0.titleID } ?? (hasMacNativeGames ? "supported.filter" : "supported.close")
            }
        }
        .onAppear {
            searchFocused = true
            focus.scope = "supported"
            focus.focused = shown.first.map { "supported.row." + $0.titleID } ?? "supported.close"
        }
        .onDisappear { covers.stop() }
    }
}

/// One row: the whole row is the target. Selecting it opens its notes under it.
private struct SupportedGameRow: View {
    let game: SupportedGame
    let detail: String
    /// "Improved in 1.5": the profile changed in this release.
    let improved: String?
    /// The owned game's build is older than the improved profile: the row offers the rebuild instead of "In your library".
    let needsRebuild: Bool
    let owned: LibraryGame?
    let cover: NSImage?
    let rebuild: (UUID) -> Void
    let expanded: Bool
    let toggle: () -> Void
    let show: (UUID) -> Void
    let move: (Int) -> Bool
    @EnvironmentObject var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: DS.Space.m) {
                    ZStack {   // the square thumbnail of every list (small = square), the banner's middle
                        DS.Color.surfaceRaised
                        if let cover { Image(nsImage: cover).resizable().scaledToFill().frame(width: DS.Control.thumbnail, height: DS.Control.thumbnail) }
                        else { Image(systemName: "gamecontroller").font(.system(size: 15, weight: .light)).foregroundStyle(DS.Color.symbolDefault) }
                    }
                    .frame(width: DS.Control.thumbnail, height: DS.Control.thumbnail)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.separator))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        HStack(alignment: .center, spacing: DS.Space.xs) {
                            Text(game.name).font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(2).multilineTextAlignment(.leading)
                            if SupportedGamesSheet.isMacNativeGamesSupported(game) {
                                DSTag(EngineUpstreamKind.macNativeGames.displayName, emphasized: true)
                            }
                            if let improved { DSTag(improved) }
                        }
                        Text(detail).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: DS.Space.s)
                    if let owned, needsRebuild {
                        Button(loc.t("supported.rebuild")) { rebuild(owned.id) }
                            .buttonStyle(DSTextButtonStyle()).help(loc.t("supported.rebuildHelp"))
                            .padTarget("supported.rebuild." + game.titleID, scope: "supported", radius: DS.Radius.chip) { rebuild(owned.id) }
                    } else if owned != nil {
                        HStack(spacing: DS.Space.xs) {
                            Circle().fill(DS.Color.statusReady).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text(loc.t("supported.owned")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Color.symbolDefault)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
                }
                .padding(.horizontal, DSSheetInsets.horizontal).padding(.vertical, DS.Space.s).frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).launcherHover()
            .padTarget("supported.row." + game.titleID, scope: "supported", radius: 6, activate: toggle, vertical: move)
            .accessibilityAddTraits(expanded ? .isSelected : [])
            .accessibilityHint(loc.t(expanded ? "supported.hideNotes" : "supported.showNotes"))
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(game.notes.isEmpty ? loc.t("supported.noNotes") : game.notes).font(DS.Font.body)
                        .foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if let owned {
                        Button(loc.t("supported.show")) { show(owned.id) }.buttonStyle(DSRowButtonStyle())
                            .padTarget("supported.show." + game.titleID, scope: "supported") { show(owned.id) }
                    }
                }
                .padding(.leading, DSSheetInsets.horizontal + DS.Control.thumbnail + DS.Space.m).padding(.trailing, DSSheetInsets.horizontal).padding(.bottom, DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: expanded)
    }
}

/// A quiet property of a supported game (Widescreen, Updated in this version): footnote text in a raised capsule. Not a DSChip,
/// which is for a state that needs attention.
