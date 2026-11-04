import SwiftUI

/// The rows of the shell settings, in the game settings' own model so the same controls draw them. The game ID tells
/// the library that a change belongs to the shell and not to a game.
enum ShellSettingsRows {
    static let gameID = "shell"
    static let hud = "shell.hud"
    static let touchSize = "shell.touchSize"
    static let touchStick = "shell.touchStick"
    static let targetPrefix = "shs.row."

    static func hudRow(_ store: ShellSettingsStore) -> SettingRow {
        SettingRow(id: hud, label: ShellStrings.text("Performance overlay"), note: ShellStrings.text("Used by games that have no choice of their own."),
                   kind: .toggle(on: "1", off: "0"), value: store.performanceHUD == true ? "1" : "0")
    }

    /// The touch controls' size for every game. The preview above the row shows it.
    static func touchSizeRow(_ store: ShellSettingsStore) -> SettingRow {
        SettingRow(id: touchSize, label: ShellStrings.text("Size"),
                   kind: .choice([SettingOption("small", ShellStrings.text("Small")), SettingOption("medium", ShellStrings.text("Medium")),
                                  SettingOption("large", ShellStrings.text("Large"))]),
                   value: store.touchSize)
    }

    /// Where the left stick sits in every game. The buttons on the right keep their place.
    static func touchStickRow(_ store: ShellSettingsStore) -> SettingRow {
        SettingRow(id: touchStick, label: ShellStrings.text("Left stick"),
                   kind: .choice([SettingOption("corner", ShellStrings.text("Corner")), SettingOption("higher", ShellStrings.text("Higher")),
                                  SettingOption("inward", ShellStrings.text("Inward"))]),
                   value: store.touchStick)
    }

    /// Under the preview: the rows are for every game, and the engine keeps the controls apart on a screen too small for a
    /// choice. A note of its own, not the rows', so the segments keep the card's width.
    static var touchNote: String { ShellStrings.text("For every game. On a screen too small for a choice, the controls stay closer to where they were.") }

    /// A change of one of the rows, from the row itself or from the list of choices.
    static func apply(_ id: String, value: String, to store: ShellSettingsStore) {
        switch id {
        case hud: store.storePerformanceHUD(value == "1")
        case touchSize: store.storeTouchSize(value)
        case touchStick: store.storeTouchStick(value)
        default: break
        }
    }
}

/// The shell's own settings: the game-data folder, the cloud-saves folder, the touch controls and the default performance
/// overlay. A game's own choices win over these, and these win over the built-in defaults. It looks like a game's
/// settings and takes a controller the same way, as a panel over the library.
struct ShellSettingsView: View {
    var store: ShellSettingsStore = .current
    var actions: ShellActions
    var onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellFocus) private var focus
    /// Counts the changes in the defaults, so the rows read the store again.
    @State private var revision = 0

    var body: some View {
        let _ = revision
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        HStack(alignment: .center) {
                            Text(ShellStrings.text("Settings")).shellType(ShellType.pageTitle)
                                .lineLimit(1).minimumScaleFactor(0.7).accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 8)
                            Button(action: onClose) { Text(ShellStrings.text("Done")) }
                                .buttonStyle(ChipButtonStyle())
                                .accessibilityIdentifier("shellSettings.close")
                                .shellTarget("shs.close", radius: 22, action: onClose)
                        }.id("shs.top")
                        SettingsGroup(title: ShellStrings.text("Game data")) {
                            SourceRow(symbol: "folder", title: store.dataFolderName ?? ShellStrings.text("No folder chosen"),
                                      note: ShellStrings.text("Games look for their data here. Keep one romfs.img per game in any folder inside. Each game is found by the image itself, so the folder names do not matter. Each game can also have a folder of its own.")) {
                                Button(ShellStrings.text("Choose folder…")) { actions.onPickShellData() }
                                    .buttonStyle(ShellButtonStyle(fills: true)).accessibilityIdentifier("shellSettings.data")
                                    .shellTarget("shs.data") { actions.onPickShellData() }
                                if store.dataFolderName != nil {
                                    Button(ShellStrings.text("Remove")) { actions.onClearShellData() }
                                        .buttonStyle(ShellButtonStyle(fills: true)).accessibilityIdentifier("shellSettings.data.remove")
                                        .shellTarget("shs.data.remove") { actions.onClearShellData() }
                                }
                            }
                        }
                        SettingsGroup(title: ShellStrings.text("Cloud saves")) {
                            SourceRow(symbol: store.cloudSavesFolderName == nil ? "icloud.slash" : "icloud",
                                      title: store.cloudSavesFolderName ?? ShellStrings.text("Off"),
                                      note: ShellStrings.text("Games without a folder of their own save here. Choose the same iCloud Drive folder you use on your Mac.")) {
                                Button(ShellStrings.text("Choose folder…")) { actions.onPickShellCloud() }
                                    .buttonStyle(ShellButtonStyle(fills: true)).accessibilityIdentifier("shellSettings.cloud")
                                    .shellTarget("shs.cloud") { actions.onPickShellCloud() }
                                if store.cloudSavesFolderName != nil {
                                    Button(ShellStrings.text("Turn off")) { actions.onClearShellCloud() }
                                        .buttonStyle(ShellButtonStyle(fills: true)).accessibilityIdentifier("shellSettings.cloud.off")
                                        .accessibilityLabel(ShellStrings.text("Turn off cloud saves"))
                                        .shellTarget("shs.cloud.off") { actions.onClearShellCloud() }
                                }
                            }
                        }
                        SettingsGroup(title: ShellStrings.text("Touch controls")) {
                            TouchControlsPreview(size: store.touchSize, stick: store.touchStick, layout: store.touchLayout)
                            TouchControlsNote()
                            ForEach([ShellSettingsRows.touchSizeRow(store), ShellSettingsRows.touchStickRow(store)]) { row in
                                SettingControl(gameID: ShellSettingsRows.gameID, row: row, targetPrefix: ShellSettingsRows.targetPrefix) {
                                    ShellSettingsRows.apply(row.id, value: $0, to: store)
                                }.equatable()
                            }
                            TouchArrangeRow(arranged: !store.touchLayout.isEmpty)
                        }
                        SettingsGroup(title: ShellStrings.text("Interface")) {
                            let hud = ShellSettingsRows.hudRow(store)
                            SettingControl(gameID: ShellSettingsRows.gameID, row: hud, targetPrefix: ShellSettingsRows.targetPrefix) {
                                ShellSettingsRows.apply(hud.id, value: $0, to: store)
                            }.equatable()
                        }
                    }
                    .padding(24).padding(.bottom, geometry.safeAreaInsets.bottom).frame(maxWidth: 640)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .bottom)
                .onChange(of: focus.id) { _, id in
                    guard let id, id.hasPrefix("shs.") else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        proxy.scrollTo(id == "shs.close" ? "shs.top" : id, anchor: id == "shs.close" ? .top : .center)
                    }
                }
            }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in revision += 1 }
    }
}
