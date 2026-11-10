import Foundation

/// An Xcode chosen for this launcher. Keep the path when a removable volume goes away so reconnecting it restores the choice.
package enum XcodeSelection {
    package static let key = "launcherXcodeApp"

    package static func app(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    package static func isXcode(_ path: String) -> Bool {
        Bundle(path: path)?.bundleIdentifier == "com.apple.dt.Xcode"
            && FileManager.default.isExecutableFile(atPath: path + "/Contents/Developer/usr/bin/xcodebuild")
    }
}
