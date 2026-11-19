import AppKit
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
        DSSheet(title: loc.t("rename.title"), message: loc.t("rename.note")) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                TextField(game.ownName(loc.lang), text: $text)
                    .textFieldStyle(.plain).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary)
                    .padding(.horizontal, DS.Space.s).frame(height: DS.Control.height)
                    .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(fieldFocused ? DS.Color.accent : DS.Color.separator))
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .accessibilityLabel(loc.t("rename.title"))
                Text(String(format: "%@: %@", loc.t("rename.placeholder"), game.ownName(loc.lang)))
                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(1).truncationMode(.middle)
            }
        } leading: {
            if !game.customName.isEmpty {
                Button(loc.t("rename.reset")) { save(""); dismiss() }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .padTarget("rename.reset", scope: "rename") { save(""); dismiss() }
            }
        } buttons: {
            Button(loc.t("saves.cancel")) { dismiss() }
                .buttonStyle(DSSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padTarget("rename.cancel", scope: "rename") { dismiss() }
            DSSheetPrimaryButton(loc.t("rename.save"), action: commit)
                .padTarget("rename.save", scope: "rename", focusColor: DS.Color.accentOn) { commit() }
        }
        .padScope("rename", focus)
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
