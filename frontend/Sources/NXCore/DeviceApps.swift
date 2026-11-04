import Foundation

/// An app installed on a device, as `devicectl device info apps` lists it.
package struct InstalledApp: Equatable {
    package let bundle: String
    package let name: String

    package init(bundle: String, name: String) { self.bundle = bundle; self.name = name }
}

/// The apps of a device (the Saves sheet's discovery and the shared app's data send both read them).
package enum InstalledApps {
    /// The arguments after `devicectl` (the Saves sheet's `DeviceControl` adds the tool).
    package static func listArguments(device: String, json: String) -> [String] {
        ["device", "info", "apps", "--device", device, "--include-default-apps", "--include-removable-apps", "--json-output", json]
    }

    /// `result.apps` of the listing. nil for JSON that cannot be read.
    package static func parse(_ data: Data) -> [InstalledApp]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any], let list = result["apps"] as? [[String: Any]] else { return nil }
        return list.compactMap { app in
            guard let bundle = app["bundleIdentifier"] as? String, !bundle.isEmpty else { return nil }
            return InstalledApp(bundle: bundle, name: app["name"] as? String ?? "")
        }
    }
}

extension ShellInstall {
    /// The shared app's bundle ID. A sideloading tool may append a team ID or put a prefix before it.
    package static let shellBundlePrefix = ShellLibrary.defaultBundleID

    /// The copies of the shared app among a device's apps, by bundle ID so the order does not change between looks.
    package static func shellApps(in apps: [InstalledApp]) -> [InstalledApp] {
        apps.filter { $0.bundle.hasPrefix(shellBundlePrefix) }.sorted { $0.bundle < $1.bundle }
    }

    /// Why the game data could not be put into the app.
    package enum DataFailure: Equatable {
        /// The device lists no app with the shared app's bundle ID.
        case appNotFound
        /// The device's list of apps could not be read (locked, not connected). Nothing was tried on the app yet.
        case noAppList
        /// The device listed the app, but the copy into it failed. devicectl's words are in the outcome's `detail`. What we believe,
        /// not verified on a device: an app that another tool signed does not allow it (no `get-task-allow`) (#491).
        case refused
    }
}
