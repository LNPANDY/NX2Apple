import SwiftUI
import NXCore
import NXModel

/// The player who plays now, in the top bar: a menu to switch players (PlayerProfileStore). It is absent while there is only
/// the default player. Adding, renaming and removing live in Settings > Library > Players (PlayersCard). Each player keeps their
/// own saves.
package struct PlayerPicker: View {
    @ObservedObject var players: PlayerProfileStore
    @EnvironmentObject var loc: Localizer

    package init(players: PlayerProfileStore, compact: Bool = false) { self.players = players; self.compact = compact }
    private let compact: Bool

    /// The widest the menu's title may be.
    package static let maxWidth: CGFloat = 140

    /// Whether the bar shows a picker at all: not for the one default player.
    package static func isVisible(profileCount: Int) -> Bool { profileCount > 1 }

    package var body: some View {
        if Self.isVisible(profileCount: players.profiles.count) {
            let name = players.displayName(players.active)
            Menu {
                ForEach(players.profiles) { profile in
                    Button {
                        players.select(profile.id)
                    } label: {
                        if profile.id == players.activeID { Label(players.displayName(profile), systemImage: "checkmark") }
                        else { Text(players.displayName(profile)) }
                    }
                }
            } label: {
                if compact { chip { icon } } else {
                    ViewThatFits(in: .horizontal) {
                        chip { HStack(spacing: 7) { icon; Text(name).font(.manrope(13.5, .semibold)).lineLimit(1).truncationMode(.tail) }
                            .frame(maxWidth: Self.maxWidth, alignment: .leading) }
                        chip { icon }
                    }
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(String(format: loc.t("players.current"), name))
            .accessibilityLabel(String(format: loc.t("players.current"), name))
            .padTarget("top.player", scope: "main", activate: { step(1) }, adjust: step)
            .padding(.trailing, 12)
        }
    }

    private func step(_ by: Int) {
        guard let index = players.profiles.firstIndex(where: { $0.id == players.activeID }), !players.profiles.isEmpty else { return }
        players.select(players.profiles[(index + by + players.profiles.count) % players.profiles.count].id)
    }

    private var icon: some View { Image(systemName: "person.crop.circle").font(.system(size: 15, weight: .medium)) }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12).frame(height: LauncherControl.height)
            .launcherGlass(in: Capsule())
            .contentShape(Capsule())
    }
}

/// Asks for a player's name: a new player, or a new name for `renaming`.
package struct PlayerNameSheet: View {
    @EnvironmentObject private var pad: PadFocus
    @ObservedObject var players: PlayerProfileStore
    let renaming: PlayerProfile?
    let close: () -> Void
    @EnvironmentObject var loc: Localizer
    @State private var name = ""
    @FocusState private var focused: Bool

    package init(players: PlayerProfileStore, renaming: PlayerProfile?, close: @escaping () -> Void) {
        self.players = players; self.renaming = renaming; self.close = close
    }

    private var valid: Bool { players.canUse(name: name, for: renaming?.id) }

    package var body: some View {
        DSSheet(title: loc.t(renaming == nil ? "players.newTitle" : "players.renameTitle"), message: renaming == nil ? loc.t("players.newNote") : "") {
            TextField(loc.t("players.name"), text: $name)
                .textFieldStyle(.plain).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary)
                .padding(.horizontal, DS.Space.s).frame(height: DS.Control.height)
                .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(focused ? DS.Color.accent : DS.Color.separator))
                .focused($focused)
                .onSubmit(commit)
                .accessibilityLabel(loc.t("players.name"))
                .padTarget("playername.field", scope: "playername", radius: DS.Radius.chip) { focused = true }
        } buttons: {
            Button(loc.t("players.cancel"), action: close).keyboardShortcut(.cancelAction)
                .buttonStyle(DSSecondaryButtonStyle())
                .padTarget("playername.cancel", scope: "playername", activate: close)
            DSSheetPrimaryButton(loc.t("players.save"), action: commit)
                .disabled(!valid)
                .padTarget("playername.save", scope: "playername", focusColor: DS.Color.accentOn, enabled: valid, activate: commit)
        }
        .padScope("playername", pad)
        .onAppear {
            if let renaming { name = players.displayName(renaming) }
            focused = true
            pad.scope = "playername"
        }
    }

    private func commit() {
        guard valid else { return }
        if let renaming { players.rename(renaming.id, to: name) } else { players.create(name: name) }
        close()
    }
}
