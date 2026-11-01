import ShellUI
import Foundation

func demoText(_ key: String.LocalizationValue) -> String {
    #if SWIFT_PACKAGE
    String(localized: key, bundle: .module)
    #else
    String(localized: key)
    #endif
}

/// Fictional fixtures. Only the demo and previews reference this file.
@MainActor enum SampleData {
    static var games: [GameDetail] {
        let tiles: [GameTile] = [
            SampleArt.tile("orbit", title: "Orbit Valley", version: "1.4.0", real: RealTitle("The Legend of Zelda: Breath of the Wild", "01007EF00011E000", "zelda-breath-of-the-wild.jpg"),
                           recentlyPlayed: ShellFormat.played(Date())),
            SampleArt.tile("tide", title: "The Quiet Tide", version: "2.0.1", real: RealTitle("Hades", "0100535012974000", "hades.jpg"),
                           recentlyPlayed: ShellFormat.played(Date().addingTimeInterval(-86_400))),
            SampleArt.tile("paper", title: "Paper Trails", version: "1.0.0", real: RealTitle("The Legend of Zelda: Tears of the Kingdom", "0100F2C0115B6000", "zelda-tears-of-the-kingdom.jpg"),
                           state: .needsGameData),
            SampleArt.tile("moon", title: "Moonlit Express", version: "3.1.0", real: RealTitle("Super Smash Bros. Ultimate", "01006A800016E000", "super-smash-bros-ultimate.jpg"),
                           state: .needsAppUpdate),
            SampleArt.tile("wild", title: "Wild Gardens", version: "1.2.0", real: RealTitle("Batman: Arkham Knight", "0100ACD0163D0000", "batman-arkham-knight.jpg"),
                           state: .broken(reason: demoText("Game files damaged"), detail: demoText("Some of this game's bundled files could not be verified."))),
            SampleArt.tile("drift", title: "Drift Atlas", version: "1.1.0", real: RealTitle("Celeste", "01002B30028F6000", "celeste.jpg")),
            // Always fictional: the icon-only fallback, a square icon inside a wide card.
            SampleArt.tile("amber", title: "Amber Hours", version: "1.0.2", real: nil)
        ]
        return tiles.map { tile in
            GameDetail(game: tile, sections: [
                SettingSection(id: "game", title: demoText("Game"), rows: [
                    SettingRow(id: "DM_OPERATION_MODE", label: demoText("Play mode"), note: demoText("The game's display and performance profile."), kind: .choice([SettingOption("handheld", demoText("Handheld")), SettingOption("docked", demoText("Docked"))]), value: "handheld"),
                    SettingRow(id: "DM_SHOW_FPS", label: demoText("Show frame rate"), kind: .toggle(on: "1", off: "0"), value: "0"),
                    SettingRow(id: "DM_LANGUAGE", label: demoText("Language"), kind: .choice([SettingOption("en-US", demoText("American English")), SettingOption("en-GB", demoText("British English")), SettingOption("ja", demoText("Japanese")), SettingOption("fr", demoText("French")), SettingOption("de", demoText("German")), SettingOption("es-419", demoText("Latin American Spanish")), SettingOption("es", demoText("Spanish")), SettingOption("it", demoText("Italian")), SettingOption("nl", demoText("Dutch")), SettingOption("fr-CA", demoText("Canadian French")), SettingOption("ru", demoText("Russian")), SettingOption("ko", demoText("Korean")), SettingOption("zh-Hant", demoText("Traditional Chinese")), SettingOption("zh-Hans", demoText("Simplified Chinese")), SettingOption("pt-BR", demoText("Brazilian Portuguese"))]), value: "en-US")
                ]),
                SettingSection(id: "controls", title: demoText("Controls"), rows: [
                    SettingRow(id: "DM_PAD_MERGE", label: demoText("All controllers are player 1"), note: demoText("Use more than one controller for the same player."), kind: .toggle(on: "1", off: "0"), value: "0")
                ]),
                SettingSection(id: "performance", title: demoText("Performance"), rows: [
                    SettingRow(id: "DM_RENDER_SCALE", label: demoText("Render scale"), note: demoText("Scale the game's 3D resolution."), kind: .range(min: 0.5, max: 1.5, step: 0.05, unit: "×"), value: "1"),
                    SettingRow(id: "DM_FPS_TARGET", label: demoText("Frame rate"), kind: .choice([SettingOption("30", demoText("30 fps")), SettingOption("60", demoText("60 fps"))]), value: "60")
                ])
            ], dataSource: tile.state == .needsGameData ? "" : demoText("This app's folder"), dataNote: demoText("Choose a RomFS folder or romfs.img on this device, an external drive, or iCloud Drive."),
                       cloudSaves: tile.id == "orbit" ? demoText("iCloud Drive / Game Saves") : nil,
                       dlc: tile.id == "orbit" ? demoText("2 additional content packs") : demoText("No additional content"), hasModifiedSettings: true)
        }
    }
    static let controllers = [
        ControllerInfo(id: "one", name: demoText("Pro Controller"), player: demoText("Player 1"), batteryPercent: 78),
        ControllerInfo(id: "two", name: demoText("Wireless Controller"), player: demoText("Player 2"), batteryPercent: 16, charging: true),
        ControllerInfo(id: "three", name: demoText("USB Controller"), player: demoText("Player 3"))
    ]
}
