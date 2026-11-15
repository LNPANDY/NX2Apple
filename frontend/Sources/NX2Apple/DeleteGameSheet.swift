import AppKit
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// The question before a game is deleted (#559): the same words as the iPhone and iPad app, the list of what goes to the Trash
/// with its size, the saves as a separate switch that starts off, and Cancel as the default button.
struct DeleteGameSheet: View {
    let game: LibraryGame
    let shellRoot: String
    /// The library entry goes once the files are gone. Called with the paths that could not be moved.
    let finished: ([String]) -> Void
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.dismiss) private var dismiss
    @State private var plan: GameDeletion?
    @State private var saves = false
    @State private var working = false

    init(game: LibraryGame, shellRoot: String, plan: GameDeletion? = nil, saves: Bool = false, finished: @escaping ([String]) -> Void = { _ in }) {
        self.game = game
        self.shellRoot = shellRoot
        self.finished = finished
        _plan = State(initialValue: plan)   // visual QA: a measured plan without files on disk
        _saves = State(initialValue: saves)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash").font(.system(size: 20, weight: .medium)).foregroundStyle(Self.red)
                    .frame(width: 40, height: 40).background(Self.red.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: loc.t("delete.question"), game.displayName(loc.lang))).font(.manrope(22, .heavy)).tracking(-0.4)
                        .fixedSize(horizontal: false, vertical: true)
                    if plan.map({ !$0.items.isEmpty || $0.saves != nil }) ?? true {   // nothing goes to the Trash for a game with no files here
                        Text(loc.t("delete.note")).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 16)
            VStack(alignment: .leading, spacing: 12) {
                if let plan {
                    card {
                        if plan.items.isEmpty {
                            Text(loc.t("delete.nothing")).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
                                .padding(.horizontal, 18).padding(.vertical, 13)
                        }
                        ForEach(Array(plan.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().opacity(0.25).padding(.leading, 18) }
                            row(item)
                        }
                    }
                    savesCard(plan.saves)
                } else {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(loc.t("free.measuring")).foregroundStyle(LauncherPalette.secondaryText) }
                        .padding(.vertical, 20)
                }
                Text(loc.t("delete.sources")).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            .padding(.horizontal, 28).padding(.bottom, 20)
            Divider().opacity(0.3)
            HStack(spacing: 12) {
                Spacer(minLength: 8)
                Button(loc.t("saves.cancel")) { dismiss() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .padTarget("delete.cancel", scope: "delete") { dismiss() }
                Button(action: delete) {
                    Text(loc.t(saves && plan?.saves != nil ? "delete.confirmSaves" : "delete.confirm")).font(.manrope(13.5, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background(Self.fill, in: Capsule())
                        .opacity(plan == nil || working ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(plan == nil || working)
                .padTarget("delete.confirm", scope: "delete", radius: 20) { delete() }
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
        }
        .padScope("delete", focus)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .launcherAppearance()
        .tint(LauncherPalette.accent)
        .onAppear { if plan == nil { measure() } }
    }

    static let red = LauncherPalette.danger
    static let fill = LauncherPalette.dynamic(dark: NSColor(srgbRed: 0.86, green: 0.25, blue: 0.24, alpha: 1),
                                              light: NSColor(srgbRed: 0xB4 / 255.0, green: 0x23 / 255.0, blue: 0x28 / 255.0, alpha: 1))

    private func title(_ kind: GameDeletion.Item.Kind) -> String {
        switch kind {
        case .macApp: loc.t("delete.part.macApp")
        case .ipa: loc.t("delete.part.ipa")
        case .iosApp: loc.t("delete.part.iosApp")
        case .archive: loc.t("delete.part.archive")
        case .shellFramework: loc.t("delete.part.shellFramework")
        case .buildFolder: loc.t("delete.part.buildFolder")
        case .log: loc.t("delete.part.log")
        case .saves: loc.t("delete.saves")
        }
    }

    /// The line under a part's name: where it is, or for the shared app what happens.
    private func detail(_ item: GameDeletion.Item) -> String {
        if item.kind == .shellFramework { return loc.t("delete.part.shellFrameworkNote") }
        guard let first = item.paths.first else { return "" }
        let shown = item.kind == .buildFolder ? (first as NSString).deletingLastPathComponent : first
        return (shown as NSString).abbreviatingWithTildeInPath
    }

    private func row(_ item: GameDeletion.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title(item.kind)).font(.manrope(14, .medium))
                Text(detail(item)).font(.manrope(11.5)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if item.bytes > 0 { sizeText(item.bytes) }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
    }

    @ViewBuilder private func savesCard(_ item: GameDeletion.Item?) -> some View {
        card {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t("delete.saves")).font(.manrope(14, .medium))
                    Text(item == nil ? loc.t("delete.noSaves") : loc.t(saves ? "delete.savesOn" : "delete.savesOff"))
                        .font(.manrope(12)).foregroundStyle(saves && item != nil ? Self.red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let item, item.bytes > 0 { sizeText(item.bytes) }
                Toggle(loc.t("delete.saves"), isOn: $saves).labelsHidden().toggleStyle(LauncherSwitchStyle()).disabled(item == nil || working)
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .padTarget("delete.saves", scope: "delete", radius: 10, activate: { if item != nil { saves.toggle() } },
                       adjust: { _ in if item != nil { saves.toggle() } })
        }
    }

    private func sizeText(_ bytes: Int64) -> some View {
        Text(FreeSpaceView.bytes(bytes)).font(.manrope(13, .semibold)).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
    }

    private func measure() {
        let game = game, root = shellRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GameDeletion.plan(for: game, shellRoot: root)
            DispatchQueue.main.async { plan = result }
        }
    }

    private func delete() {
        guard let plan, !working else { return }
        working = true
        let withSaves = saves
        DispatchQueue.global(qos: .userInitiated).async {
            let failed = plan.run(saves: withSaves)
            DispatchQueue.main.async {
                working = false
                dismiss()
                finished(failed)
            }
        }
    }
}

extension View {
    /// The Delete sheet of `game`, and the controller's scope while it is open. Its own modifier keeps LauncherView's chain short.
    func deleteGameSheet(_ game: Binding<LibraryGame?>, shellRoot: String, library: GameLibrary, loc: Localizer, pad: PadFocus,
                         scope: @escaping () -> String) -> some View {
        sheet(item: game) { game in
            DeleteGameSheet(game: game, shellRoot: shellRoot) { failed in
                library.remove(game.id)
                if !failed.isEmpty { library.error = String(format: loc.t("delete.failed"), failed.joined(separator: "\n")) }
            }
            .environmentObject(pad)
        }
        .onChange(of: game.wrappedValue?.id) { id in pad.scope = id != nil ? "delete" : scope() }
    }
}
