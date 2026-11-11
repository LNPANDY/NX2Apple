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
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: String?
    @FocusState private var searchFocused: Bool

    /// The cover slot: 112 x 63 pt, decoded at 2x.
    static let coverPixels = 224

    init(games: [SupportedGame], owned: @escaping (String) -> LibraryGame?, covers: @escaping @autoclosure () -> SupportedCovers,
         showInLibrary: @escaping (UUID) -> Void) {
        self.games = games
        self.owned = owned
        _covers = StateObject(wrappedValue: covers())
        self.showInLibrary = showInLibrary
    }

    /// At most 720 tall and 80 shorter than the screen.
    static func height(screen: CGFloat) -> CGFloat { LauncherSheet.maxHeight(screen: screen) }

    var shown: [SupportedGame] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? games : games.filter { game in
            [game.name, game.titleID, owned(game.titleID)?.displayName(loc.lang) ?? ""].contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    func detail(_ game: SupportedGame) -> String {
        var parts: [String] = []
        if game.edition == .switch2 { parts.append(loc.t("switch2.badge")) }
        parts.append(game.version.map { String(format: loc.t("supported.version"), $0) } ?? loc.t("supported.noVersion"))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc.t("supported.title")).font(.manrope(26, .heavy)).tracking(-0.6)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(LauncherPalette.secondaryText)
                    TextField(loc.t("supported.search"), text: $search).textFieldStyle(.plain).font(.manrope(14))
                        .focused($searchFocused).accessibilityLabel(loc.t("supported.search"))
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(LauncherPalette.menuFill, in: Capsule())
                .overlay(Capsule().strokeBorder(LauncherPalette.ink(searchFocused ? 0.22 : 0.10)))
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 16)
            Divider().opacity(0.3)
            if shown.isEmpty {
                Text(loc.t("supported.none")).font(.manrope(14)).foregroundStyle(LauncherPalette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { game in
                            SupportedGameRow(game: game, detail: detail(game), owned: owned(game.titleID), cover: covers.image(game.titleID),
                                             expanded: selected == game.titleID,
                                             toggle: { selected = selected == game.titleID ? nil : game.titleID },
                                             show: { id in showInLibrary(id); dismiss() })
                                .onAppear { covers.appear(game.titleID) }
                                .onDisappear { covers.disappear(game.titleID) }
                            Divider().opacity(0.25).padding(.leading, 30)
                        }
                    }
                }
            }
            Divider().opacity(0.3)
            HStack {
                Text(String(format: loc.t("supported.count"), shown.count)).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText)
                Spacer()
                Button(loc.t("free.done")) { dismiss() }
                    .buttonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    .padTarget("supported.close", scope: "supported") { dismiss() }
            }
            .padding(.horizontal, 30).padding(.vertical, 14)
        }
        .background(Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true))   // Cmd+F, as in the library: the search of this list
        .padScope("supported", focus)
        .frame(width: 680)
        .frame(maxHeight: Self.height(screen: NSScreen.main?.visibleFrame.height ?? 800))
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .launcherAppearance()
        .tint(LauncherPalette.accent)
        .onAppear { searchFocused = true }
        .onDisappear { covers.stop() }
    }
}

/// One row: the whole row is the target. Selecting it opens its notes under it.
private struct SupportedGameRow: View {
    let game: SupportedGame
    let detail: String
    let owned: LibraryGame?
    let cover: NSImage?
    let expanded: Bool
    let toggle: () -> Void
    let show: (UUID) -> Void
    @EnvironmentObject var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 16) {
                    ZStack {
                        LauncherPalette.surface
                        if let cover { Image(nsImage: cover).resizable().scaledToFill() }
                        else { Image(systemName: "gamecontroller").font(.system(size: 18, weight: .light)).foregroundStyle(LauncherPalette.secondaryText) }
                    }
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(LauncherPalette.cardBorder))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.name).font(.manrope(14.5, .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        Text(detail).font(.manrope(12.5)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 12)
                    if owned != nil {
                        Text(loc.t("supported.owned")).font(.manrope(12.5, .semibold)).foregroundStyle(LauncherPalette.ready)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(LauncherPalette.secondaryText)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
                }
                .padding(.horizontal, 30).padding(.vertical, 14).frame(minHeight: 91)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).launcherHover()
            .padTarget("supported.row." + game.titleID, scope: "supported", radius: 6, activate: toggle)   // a controller opens the notes too
            .accessibilityAddTraits(expanded ? .isSelected : [])
            .accessibilityHint(loc.t(expanded ? "supported.hideNotes" : "supported.showNotes"))
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(game.notes.isEmpty ? loc.t("supported.noNotes") : game.notes).font(.manrope(13))
                        .foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    if let owned {
                        Button(loc.t("supported.show")) { show(owned.id) }.buttonStyle(LauncherSecondaryButtonStyle())
                            .padTarget("supported.show." + game.titleID, scope: "supported") { show(owned.id) }
                    }
                }
                .padding(.leading, 158).padding(.trailing, 30).padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: expanded)
    }
}
