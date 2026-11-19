import SwiftUI
import NXCore
import NXModel

/// Settings > Library > Players: one row per player with Rename and Remove, and Add player below. A player is a save folder
/// (PlayerProfile), so the note says what a second player does and does not get: cloud saves stay with the first player.
package struct PlayersCard: View {
    @ObservedObject var players: PlayerProfileStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
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
                            .padTarget("players.use." + profile.id, scope: "main") { players.select(profile.id) }
                    }
                    Button(loc.t("players.renameButton")) { naming = Naming(renaming: profile) }
                        .accessibilityLabel(String(format: loc.t("players.renameFor"), name))
                        .padTarget("players.rename." + profile.id, scope: "main") { naming = Naming(renaming: profile) }
                    if !profile.isDefault {
                        Button(loc.t("players.removeButton")) { removing = profile }
                            .accessibilityLabel(String(format: loc.t("players.removeFor"), name))
                            .padTarget("players.remove." + profile.id, scope: "main") { removing = profile }
                    }
                }
            }
            CardDivider()
            CardRow(loc.t("players.addRow")) {
                Button(loc.t("players.new")) { naming = Naming() }
                    .padTarget("players.add", scope: "main") { naming = Naming() }
            }
        }
        .buttonStyle(LauncherSecondaryButtonStyle())
        .sheet(item: $naming) { naming in
            PlayerNameSheet(players: players, renaming: naming.renaming) { self.naming = nil }
                .environmentObject(loc)
        }
        .sheet(item: $removing) { profile in
            LauncherConfirmSheet(title: String(format: loc.t("players.removeAsk"), players.displayName(profile)), subtitle: "", note: loc.t("players.removeNote"),
                cancelTitle: loc.t("players.cancel"), confirmTitle: loc.t("players.remove"), destructive: true, scope: "playerremove",
                cancel: { removing = nil }, confirm: { players.remove(profile.id); removing = nil })
        }
        .onChange(of: naming?.id) { value in pad.scope = value == nil ? "main" : "playername" }
        .onChange(of: removing?.id) { value in pad.scope = value == nil ? "main" : "playerremove" }
    }
}
