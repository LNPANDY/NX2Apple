import SwiftUI
import NXCore
import NXModel

/// The player who plays now, in the top bar: a menu to switch players (PlayerProfileStore). It is absent while there is only
/// the default player. Adding, renaming and removing live in Settings > Library > Players (PlayersCard). Each player keeps their
/// own saves.
package struct PlayerPicker: View {
    @ObservedObject var players: PlayerProfileStore
    @EnvironmentObject var loc: Localizer

    package init(players: PlayerProfileStore) { self.players = players }

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
                ViewThatFits(in: .horizontal) {
                    chip { HStack(spacing: 7) { icon; Text(name).font(.manrope(13.5, .semibold)).lineLimit(1).truncationMode(.tail) }
                        .frame(maxWidth: Self.maxWidth, alignment: .leading) }
                    chip { icon }
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.trailing, 12)
            .help(String(format: loc.t("players.current"), name))
            .accessibilityLabel(String(format: loc.t("players.current"), name))
        }
    }

    private var icon: some View { Image(systemName: "person.crop.circle").font(.system(size: 15, weight: .medium)) }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(LauncherPalette.menuFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LauncherPalette.secondaryBorder))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Asks for a player's name: a new player, or a new name for `renaming`.
struct PlayerNameSheet: View {
    @ObservedObject var players: PlayerProfileStore
    let renaming: PlayerProfile?
    let close: () -> Void
    @EnvironmentObject var loc: Localizer
    @State private var name = ""
    @FocusState private var focused: Bool

    private var valid: Bool { players.canUse(name: name, for: renaming?.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.t(renaming == nil ? "players.newTitle" : "players.renameTitle")).font(.manrope(20, .heavy))
            if renaming == nil {
                Text(loc.t("players.newNote")).font(.manrope(13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(loc.t("players.name"), text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button(loc.t("players.cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(loc.t("players.save"), action: commit)
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(24).frame(width: 380)
        .onAppear {
            if let renaming { name = players.displayName(renaming) }
            focused = true
        }
    }

    private func commit() {
        guard valid else { return }
        if let renaming { players.rename(renaming.id, to: name) } else { players.create(name: name) }
        close()
    }
}
