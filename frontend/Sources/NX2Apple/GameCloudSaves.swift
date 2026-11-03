import Foundation
import NXCore

/// One Mac game's cloud saves folder on disk (#499): read where dm/mac/launcher.c reads it (CloudSaveSync), changed where it
/// counts, and the last session's sync from the game's log.
///
/// A change goes to the place the engine reads first among those that set the folder: the player's env.txt when it or the
/// app's own env.txt has a `DM_SAVE_SYNC` line (the app's is inside the signed app and is not changed, the player's wins over
/// it), else `cloudSaves.folder` in the app's preferences domain, as the app's own settings window does.
struct GameCloudSaves {
    let titleID: String
    let appPath: String
    var home = NSHomeDirectory()
    var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    var readPreference: () -> String?
    var writePreference: (String?) -> Void

    init(titleID: String, appPath: String) {
        self.titleID = titleID
        self.appPath = appPath
        let domain = SavedChoices.domain(app: appPath, titleID: titleID) as CFString
        let key = CloudSaveSync.preferenceKey as CFString
        readPreference = { CFPreferencesCopyAppValue(key, domain) as? String }
        writePreference = { value in
            CFPreferencesSetAppValue(key, value as CFString?, domain)
            CFPreferencesAppSynchronize(domain)
        }
    }

    var playerEnv: URL { support.appendingPathComponent("nxnative").appendingPathComponent(titleID).appendingPathComponent("env.txt") }
    var appEnv: URL { URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Resources/dm/env.txt") }

    private static func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    var setting: CloudSaveSync.Setting {
        CloudSaveSync.resolve(playerEnv: Self.text(playerEnv), appEnv: appPath.isEmpty ? nil : Self.text(appEnv),
                              preference: readPreference(), home: home)
    }

    /// Whether a line of an env.txt sets the folder: then the player's env.txt is where a change counts.
    private var envDecides: Bool { [.playerEnv, .appEnv].contains(setting.source) }

    /// Syncs through `folder` from the game's next start.
    func choose(_ folder: String) throws { try set(folder) }

    /// Turns cloud saves off from the game's next start. An env.txt line becomes `DM_SAVE_SYNC=0`, so the app's own line
    /// cannot turn them on again.
    func turnOff() throws { try set(nil) }

    private func set(_ folder: String?) throws {
        if envDecides {
            try FileManager.default.createDirectory(at: playerEnv.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(CloudSaveSync.settingEnv(Self.text(playerEnv), to: folder ?? "0").utf8).write(to: playerEnv, options: .atomic)
        }
        writePreference(folder)
    }

    /// The last session's sync and when that session's log was last written, nil when the game has no log yet.
    func lastSession() -> (state: CloudSaveSync.LogState?, date: Date?)? {
        guard let log = GameLog.latest(titleID: titleID, appPath: appPath, home: home) else { return nil }
        let date = (try? FileManager.default.attributesOfItem(atPath: log.path))?[.modificationDate] as? Date
        let text = (try? Data(contentsOf: log)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return (CloudSaveSync.state(fromLog: text), date)
    }
}
