import Foundation

/// Reseals an installed app after a cover was written into it, using the identity already on the app.
/// An unsigned folder is left alone. An ad-hoc app is sealed as ad-hoc again. Anything else keeps its certificate.
package enum CoverSeal {
    /// Nil when the app was resealed, or when it had nothing to reseal.
    /// A string when a signed app could not be resealed.
    /// `run` executes one command. The array is the full argv, with the executable first, and the value is the exit status.
    package static func seal(app: String, run: ([String]) -> Int32) -> String? {
        guard let identity = signingIdentity(of: app) else { return nil }
        for framework in embeddedFrameworks(in: app) {
            if run(signCommand(identity, framework)) != 0 {
                let name = (framework as NSString).lastPathComponent
                return "Could not sign \(name) again after the cover changed"
            }
        }
        if run(signCommand(identity, app)) != 0 {
            return "Could not sign the app again after the cover changed"
        }
        return nil
    }

    private static func signCommand(_ identity: String, _ path: String) -> [String] {
        ["/usr/bin/codesign", "--force", "--sign", identity, "--preserve-metadata=identifier,entitlements,flags", path]
    }

    /// The first Authority= value from `codesign -d`, or `-` when that display says the app is ad-hoc.
    /// Nil when the display fails or names no identity. The exit status alone cannot carry the name, so this read captures the tool's output here.
    private static func signingIdentity(of app: String) -> String? {
        let shown = capture(["/usr/bin/codesign", "-d", "--verbose=2", app])
        guard shown.status == 0 else { return nil }
        return identity(in: shown.output)
    }

    /// The certificate name, or `-` for an ad-hoc signature. Nil when the text names neither.
    package static func identity(in output: String) -> String? {
        var adhoc = false
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("Signature=adhoc") || text.contains("(adhoc)") { adhoc = true }
            guard let range = text.range(of: "Authority=") else { continue }
            let value = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, value != "-" { return String(value) }
        }
        return adhoc ? "-" : nil
    }

    /// Frameworks inside the app, deepest first, so each nested bundle is signed before the one that contains it.
    private static func embeddedFrameworks(in app: String) -> [String] {
        var found: [String] = []
        func collect(_ folder: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
            for name in names.sorted() where name.hasSuffix(".framework") {
                let path = (folder as NSString).appendingPathComponent(name)
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { continue }
                collect((path as NSString).appendingPathComponent("Frameworks"))
                found.append(path)
            }
        }
        collect((app as NSString).appendingPathComponent("Frameworks"))
        return found
    }

    /// Runs one command and keeps stdout and stderr together. A command that does not start counts as a failure.
    private static func capture(_ argv: [String]) -> (status: Int32, output: String) {
        guard let executable = argv.first else { return (1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
