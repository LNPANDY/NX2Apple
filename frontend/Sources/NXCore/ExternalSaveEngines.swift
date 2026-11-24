import Foundation

/// Save descriptor for MacNativeGames builds: 10 curated ports use MNG's own `TOTK_PROFILE_DIR` layout
/// (`MacNativeGames/<GAME_FOLDER>/profile/save`), while `ss` and `worldend` wrap legacy `dm` but override `DM_SAVE`.
package struct MacNativeGamesSaveEngine: SaveEngine {
    package init() {}
    package var saveKey: String { "TOTK_PROFILE_DIR" }
    package var syncKey: String { "" }
    package var choiceKey: String { "" }
    package var unaskedChoice: String? { nil }
    package var psoUserKey: String? { nil }
    package var savesInLibraryFolder: Bool { false }
    package var managesSavesInLauncher: Bool { false }

    /// Data directories for legacy `dm`-wrapped MNG ports that force-override `DM_SAVE` inside `app/launcher.c`.
    private static let legacyDmFolders: [String: String] = [
        "01002DA013484000": "The Legend of Zelda Skyward Sword HD", // games/ss/app/launcher.c
        "010048900CF64000": "MacNativeGames/Worldend Syndrome",     // games/worldend/app/launcher.c
    ]

    /// `GAME_FOLDER` directories under `~/Library/Application Support/MacNativeGames/` for the 10 custom-runtime ports.
    private static let profileFolders: [String: [String]] = [
        "0100F2C0115B6000": ["TOTK"],                     // Tears of the Kingdom
        "01007EF00011E000": ["BotW"],                     // Breath of the Wild
        "0400486024DEC000": ["OcarinaOfTime"],            // Ocarina of Time (Switch 2)
        "040074A01BF12000": ["Bananza"],                  // Donkey Kong Bananza (Switch 2)
        "0400A3A01EE4C000": ["Pokopia"],                  // Pokémon Pokopia (Switch 2)
        "010093801237C000": ["Dread"],                    // Metroid Dread
        "0100FE701475A000": ["TMNT"],                     // TMNT: Shredder's Revenge
        "01006F8002326000": ["ACNH", "ACNH-3.0.3", "ACNH-3.0.1"], // Animal Crossing: New Horizons
        "01008CF01BAAC000": ["EoW"],                      // Echoes of Wisdom
        "0100000000010000": ["Odyssey"],                  // Super Mario Odyssey
    ]

    package func defaultSave(titleID: String, support: URL) -> URL {
        let tid = titleID.uppercased()
        if let legacy = Self.legacyDmFolders[tid] {
            return support.appendingPathComponent(legacy, isDirectory: true).appendingPathComponent("save", isDirectory: true)
        }
        let candidates = Self.profileFolders[tid] ?? [tid]
        let fm = FileManager.default
        let base = support.appendingPathComponent("MacNativeGames", isDirectory: true)
        let folderName = candidates.first {
            fm.fileExists(atPath: base.appendingPathComponent($0, isDirectory: true).appendingPathComponent("profile/save").path)
        } ?? candidates[0]
        return base
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("profile", isDirectory: true)
            .appendingPathComponent("save", isDirectory: true)
    }

    package func deletionPaths(titleID: String, support: URL) -> [String] {
        let tid = titleID.uppercased()
        if let legacy = Self.legacyDmFolders[tid] {
            let save = support.appendingPathComponent(legacy, isDirectory: true).appendingPathComponent("save", isDirectory: true)
            return [save.path, save.path + "_device", save.path + "-backups"] + SaveUsers.userPaths(save: save)
        }
        let mngRoot = support.appendingPathComponent("MacNativeGames", isDirectory: true)
        let folders = Self.profileFolders[tid] ?? []
        return folders.flatMap { name -> [String] in
            let data = mngRoot.appendingPathComponent(name, isDirectory: true)
            let profile = data.appendingPathComponent("profile", isDirectory: true)
            return [
                profile.appendingPathComponent("save", isDirectory: true).path,
                profile.appendingPathComponent("users.txt").path,
                data.appendingPathComponent("data/backups", isDirectory: true).path,
            ]
        }
    }

    package func playerEnvironment(name: String) -> [String: String] { [:] }
    package func takesChoice(app: String) -> Bool { false }
    package func reportCommand(app: String, wait: TimeInterval) -> [String]? { nil }
    package func sendCommand(app: String) -> [String]? { nil }
}

/// Save descriptor for S2Arm builds: `s2arm-launch` hardcodes `~/Library/Application Support/NX2Apple/s2arm-data/<TID>/SaveData`
/// alongside Ryujinx's internal mirror under `ryu-data/bis/user/save`.
package struct S2ArmSaveEngine: SaveEngine {
    package init() {}
    package var saveKey: String { "S2A_SAVE_FOLDER" }
    package var syncKey: String { "" }
    package var choiceKey: String { "" }
    package var unaskedChoice: String? { nil }
    package var psoUserKey: String? { nil }
    package var savesInLibraryFolder: Bool { false }
    package var managesSavesInLauncher: Bool { false }

    package static func dataRoot(titleID: String, support: URL) -> URL {
        support
            .appendingPathComponent("NX2Apple", isDirectory: true)
            .appendingPathComponent("s2arm-data", isDirectory: true)
            .appendingPathComponent(titleID.uppercased(), isDirectory: true)
    }

    package func defaultSave(titleID: String, support: URL) -> URL {
        Self.dataRoot(titleID: titleID, support: support).appendingPathComponent("SaveData", isDirectory: true)
    }

    package func deletionPaths(titleID: String, support: URL) -> [String] {
        let root = Self.dataRoot(titleID: titleID, support: support)
        let ryu = root.appendingPathComponent("ryu-data", isDirectory: true)
        return [
            root.appendingPathComponent("SaveData", isDirectory: true).path,
            ryu.appendingPathComponent("bis/user/save", isDirectory: true).path,
            ryu.appendingPathComponent("savedata-state.txt").path,
            root.appendingPathComponent("saves", isDirectory: true).path,
        ]
    }

    package func playerEnvironment(name: String) -> [String: String] { [:] }
    package func takesChoice(app: String) -> Bool { false }
    package func reportCommand(app: String, wait: TimeInterval) -> [String]? { nil }
    package func sendCommand(app: String) -> [String]? { nil }
}
