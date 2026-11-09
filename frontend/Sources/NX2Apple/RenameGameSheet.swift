import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Manage > Rename (LNPANDY/NX2Apple#895): the name the library shows for a game, in every language, in place of the game's own
/// names (a cartridge with no title in the launcher's language, or a name the player prefers). Empty goes back to the game's names.
/// It changes only what the launcher shows: the app, its bundle name and the artwork lookup keep the game's own name.
struct RenameGameSheet: View {
    let game: LibraryGame
    let save: (String) -> Void
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var fieldFocused: Bool

    init(game: LibraryGame, save: @escaping (String) -> Void = { _ in }) {
        self.game = game
        self.save = save
        _text = State(initialValue: game.customName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(loc.t("rename.title")).font(.manrope(22, .heavy)).tracking(-0.4)
                Text(loc.t("rename.note")).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 16)
            TextField(game.ownName(loc.lang), text: $text)
                .textFieldStyle(.plain).font(.manrope(16, .medium))
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LauncherPalette.ink(fieldFocused ? 0.25 : 0.08)))
                .focused($fieldFocused)
                .onSubmit(commit)
                .accessibilityLabel(loc.t("rename.title"))
                .padding(.horizontal, 28).padding(.bottom, 8)
            Text(String(format: "%@: %@", loc.t("rename.placeholder"), game.ownName(loc.lang)))
                .font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 30).padding(.bottom, 20)
            Divider().opacity(0.3)
            HStack(spacing: 12) {
                if !game.customName.isEmpty {
                    Button(loc.t("rename.reset")) { save(""); dismiss() }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .padTarget("rename.reset", scope: "rename") { save(""); dismiss() }
                }
                Spacer(minLength: 8)
                Button(loc.t("saves.cancel")) { dismiss() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .padTarget("rename.cancel", scope: "rename") { dismiss() }
                Button(action: commit) {
                    Text(loc.t("rename.save")).font(.manrope(13.5, .bold))
                        .padding(.horizontal, 20).padding(.vertical, 9)
                }
                .buttonStyle(LauncherActionButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padTarget("rename.save", scope: "rename", radius: 20) { commit() }
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
        }
        .padScope("rename", focus)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .launcherAppearance()
        .tint(LauncherPalette.accent)
        .onAppear { fieldFocused = true }
    }

    private func commit() {
        save(text)
        dismiss()
    }
}

extension View {
    /// The Rename sheet of `game`, and the controller's scope while it is open.
    func renameGameSheet(_ game: Binding<LibraryGame?>, library: GameLibrary, pad: PadFocus, scope: @escaping () -> String) -> some View {
        sheet(item: game) { game in
            RenameGameSheet(game: game) { library.rename(game.id, to: $0) }.environmentObject(pad)
        }
        .onChange(of: game.wrappedValue?.id) { id in pad.scope = id != nil ? "rename" : scope() }
    }
}
