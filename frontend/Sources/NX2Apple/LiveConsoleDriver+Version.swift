import Foundation
import NXCore

/// The version a console game shows, read from its build once per path.
extension LiveConsoleDriver {
    /// The version of the build the library knows: the Mac app's Info.plist (pack_app.py writes it, version(plist:)), else the
    /// iPhone app's, else the one inside the IPA. Empty only when none of them states one.
    func version(of game: LibraryGame) -> String {
        for path in [game.appPath, game.iosAppPath, game.ipaPath] where !path.isEmpty {
            if let cached = versions[path] { if !cached.isEmpty { return cached }; continue }
            let found = Self.version(at: path)
            versions[path] = found
            if !found.isEmpty { return found }
        }
        return ""
    }

    /// The display version in a build: a .app (Contents/Info.plist), an iOS .app (Info.plist) or an IPA (Payload/*.app/Info.plist).
    nonisolated static func version(at path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "ipa" {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", path, "Payload/*.app/Info.plist"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return version(plist: data)
        }
        for relative in ["Contents/Info.plist", "Info.plist"] {
            if let data = try? Data(contentsOf: url.appendingPathComponent(relative)) { let v = version(plist: data); if !v.isEmpty { return v } }
        }
        return ""
    }

    /// A Mac app packed with DMPackageVersion states its version in DMDisplayVersion, else (an update packed from a dump or a NUP without control data) only as the
    /// packed version, v458752: its CFBundleShortVersionString is then 1.0, not what runs (#953). The base game packed without a display version (v0) states none.
    /// Other builds state it in CFBundleShortVersionString.
    nonisolated static func version(plist data: Data) -> String {
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return "" }
        let trimmed = { (key: String) in ((info[key] as? String) ?? "").trimmingCharacters(in: .whitespaces) }
        let package = trimmed("DMPackageVersion")
        if !package.isEmpty {
            let display = trimmed("DMDisplayVersion")
            return !display.isEmpty ? display : package == "v0" ? "" : package
        }
        let short = trimmed("CFBundleShortVersionString")
        return short.isEmpty ? trimmed("CFBundleVersion") : short
    }
}

/// Calls `handler` whenever one of the object's key-value observable properties changes.
final class KeyValueWatcher: NSObject {
    private let object: NSObject   // held, so it cannot go away while observed
    private let keys: [String]
    private let handler: () -> Void
    init(object: NSObject, keys: [String], handler: @escaping () -> Void) {
        self.object = object; self.keys = keys; self.handler = handler
        super.init()
        for key in keys { object.addObserver(self, forKeyPath: key, options: [], context: nil) }
    }
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) { handler() }
    deinit { for key in keys { object.removeObserver(self, forKeyPath: key) } }
}
