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
    let appVersion: String
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: String?
    @FocusState private var searchFocused: Bool

    /// The cover slot: 112 x 63 pt, decoded at 2x.
    static let coverPixels = 224

    init(games: [SupportedGame], owned: @escaping (String) -> LibraryGame?, covers: @escaping @autoclosure () -> SupportedCovers,
         showInLibrary: @escaping (UUID) -> Void, appVersion: String = AppUpdateStore.appVersion, expanded: String? = nil) {
        _selected = State(initialValue: expanded)   // visual QA: a row with its notes open
        self.games = games
        self.owned = owned
        _covers = StateObject(wrappedValue: covers())
        self.showInLibrary = showInLibrary
        self.appVersion = appVersion
    }

    /// At most 720 tall and 80 shorter than the screen.
    static func height(screen: CGFloat) -> CGFloat { LauncherSheet.maxHeight(screen: screen) }

    static func isUpdatedInCurrentRelease(titleID: String, appVersion: String = AppUpdateStore.appVersion) -> Bool {
        GameUpdateCatalog.catalogVersion(for: titleID) == GameUpdateCatalog.releaseBaseVersion(appVersion)
    }

    static func matchesSearch(_ game: SupportedGame, needle: String, ownedName: String, badgeName: String = "") -> Bool {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let updated = GameUpdateCatalog.catalogVersion(for: game.titleID) ?? ""
        var fields = [game.name, game.titleID, ownedName, updated]
        if game.fullScreen {
            if badgeName.isEmpty {
                fields.append(contentsOf: Lang.all.map { L10n.string("widescreen.badge", $0) })
            } else {
                fields.append(badgeName)
            }
        }
        return fields.contains {
            $0.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func detailText(for game: SupportedGame, t: (String) -> String) -> String {
        var parts: [String] = []
        if game.edition == .switch2 { parts.append(t("switch2.badge")) }
        parts.append(game.version.map { String(format: t("supported.version"), $0) } ?? t("supported.noVersion"))
        if let updated = GameUpdateCatalog.catalogVersion(for: game.titleID) {
            parts.append(String(format: t("supported.lastUpdated"), updated))
        }
        return parts.joined(separator: " · ")
    }

    var shown: [SupportedGame] {
        let badge = loc.t("widescreen.badge")
        return games.filter { game in
            Self.matchesSearch(game, needle: search, ownedName: owned(game.titleID)?.displayName(loc.lang) ?? "", badgeName: badge)
        }
    }

    func detail(_ game: SupportedGame) -> String {
        Self.detailText(for: game, t: { loc.t($0) })
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
                .overlay(Capsule().strokeBorder(searchFocused ? DS.Color.accent : DS.Color.separator))
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
                            SupportedGameRow(game: game, detail: detail(game),
                                             isCurrentUpdate: Self.isUpdatedInCurrentRelease(titleID: game.titleID, appVersion: appVersion),
                                             owned: owned(game.titleID), cover: covers.image(game.titleID),
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
    let isCurrentUpdate: Bool
    let owned: LibraryGame?
    let cover: NSImage?
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
                    ZStack {
                        DS.Color.surfaceRaised
                        if let cover { Image(nsImage: cover).resizable().scaledToFill() }
                        else { Image(systemName: "gamecontroller").font(.system(size: 18, weight: .light)).foregroundStyle(DS.Color.symbolDefault) }
                    }
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.separator))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        HStack(alignment: .center, spacing: DS.Space.xs) {
                            Text(game.name).font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(2).multilineTextAlignment(.leading)
                            if game.fullScreen { SupportedTag(loc.t("widescreen.badge")).help(loc.t("widescreen.help")) }
                            if isCurrentUpdate { SupportedTag(loc.t("supported.updatedCurrent")) }
                        }
                        Text(detail).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: DS.Space.s)
                    if owned != nil {
                        HStack(spacing: DS.Space.xs) {
                            Circle().fill(DS.Color.statusReady).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text(loc.t("supported.owned")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Color.symbolDefault)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
                }
                .padding(.horizontal, DSSheetInsets.horizontal).padding(.vertical, DS.Space.s).frame(minHeight: 91)
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
                .padding(.leading, DSSheetInsets.horizontal + 112 + DS.Space.m).padding(.trailing, DSSheetInsets.horizontal).padding(.bottom, DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: expanded)
    }
}

/// A quiet property of a supported game (Widescreen, Updated in this version): footnote text in a raised capsule. Not a DSChip,
/// which is for a state that needs attention.
private struct SupportedTag: View {
    init(_ title: String) { self.title = title }
    let title: String
    var body: some View {
        Text(title).font(DS.Font.footnote).foregroundStyle(DS.Color.textSecondary).lineLimit(1).fixedSize()
            .padding(.horizontal, DS.Space.xs).padding(.vertical, 2)
            .background(DS.Color.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.Color.separator))
    }
}
