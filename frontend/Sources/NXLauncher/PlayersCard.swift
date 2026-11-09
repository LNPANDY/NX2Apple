import SwiftUI
import NXCore
import NXModel

/// Settings > Library > Players: one row per player with Rename and Remove, and Add player below. A player is a save folder
/// (PlayerProfile), so the note says what a second player does and does not get: cloud saves stay with the first player.
package struct PlayersCard: View {
    @ObservedObject var players: PlayerProfileStore
    @EnvironmentObject var loc: Localizer
    @State private var naming: Naming?
    @State private var removing: PlayerProfile?

    private struct Naming: Identifiable {
        var renaming: PlayerProfile?
        var id: String { renaming?.id ?? "+new" }
    }

    package init(players: PlayerProfileStore) { self.players = players }

    package var body: some View {
        CardGroup(loc.t("players.group"), footnote: loc.t("players.cloudNote")) {
            ForEach(Array(players.profiles.enumerated()), id: \.element.id) { index, profile in
                if index > 0 { CardDivider() }
                let name = players.displayName(profile)
                CardRow(name, detail: profile.id == players.activeID ? loc.t("players.playing") : "") {
                    if profile.id != players.activeID {
                        Button(loc.t("players.use")) { players.select(profile.id) }
                            .accessibilityLabel(String(format: loc.t("players.useFor"), name))
                    }
                    Button(loc.t("players.renameButton")) { naming = Naming(renaming: profile) }
                        .accessibilityLabel(String(format: loc.t("players.renameFor"), name))
                    if !profile.isDefault {
                        Button(loc.t("players.removeButton")) { removing = profile }
                            .accessibilityLabel(String(format: loc.t("players.removeFor"), name))
                    }
                }
            }
            CardDivider()
            CardRow(loc.t("players.addRow")) {
                Button(loc.t("players.new")) { naming = Naming() }
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
        .sheet(item: $naming) { naming in
            PlayerNameSheet(players: players, renaming: naming.renaming) { self.naming = nil }
                .environmentObject(loc)
        }
        .confirmationDialog(String(format: loc.t("players.removeAsk"), removing.map(players.displayName) ?? ""),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(loc.t("players.remove"), role: .destructive) {
                if let removing { players.remove(removing.id) }
                removing = nil
            }
            Button(loc.t("players.cancel"), role: .cancel) { removing = nil }
        } message: {
            Text(loc.t("players.removeNote"))
        }
    }
}
