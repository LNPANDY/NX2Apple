import SwiftUI
import NXCore
import NXModel

/// The player who plays now, in the top bar: a menu to switch players, add one, rename or remove the current one
/// (PlayerProfileStore). Each player keeps their own saves.
package struct PlayerPicker: View {
    @ObservedObject var players: PlayerProfileStore
    @EnvironmentObject var loc: Localizer
    @State private var naming: Naming?
    @State private var removing: PlayerProfile?

    /// The name sheet: a new player, or a new name for one.
    private struct Naming: Identifiable {
        var renaming: PlayerProfile?
        var id: String { renaming?.id ?? "+new" }
    }

    package init(players: PlayerProfileStore) { self.players = players }

    package var body: some View {
        Menu {
            ForEach(players.profiles) { profile in
                Button {
                    players.select(profile.id)
                } label: {
                    if profile.id == players.activeID { Label(players.displayName(profile), systemImage: "checkmark") }
                    else { Text(players.displayName(profile)) }
                }
            }
            Divider()
            Button(loc.t("players.new")) { naming = Naming() }
            Button(loc.t("players.rename")) { naming = Naming(renaming: players.active) }
            if !players.active.isDefault {
                Button(loc.t("players.remove"), role: .destructive) { removing = players.active }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle").font(.system(size: 15, weight: .medium))
                Text(players.displayName(players.active)).font(.manrope(13.5, .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(loc.t("players.help"))
        .accessibilityLabel(String(format: loc.t("players.current"), players.displayName(players.active)))
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
                Button(loc.t(renaming == nil ? "players.add" : "players.save"), action: commit)
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
