import Foundation
import PayloadKit

/// Production payload intake. Tests can pass a store rooted at a temporary
/// directory. Unsigned previews never advertise device payload support.
public enum ShellPayloads {
    public static func live(bundle: Bundle = .main, documents: URL? = nil) -> PayloadStore? {
        guard let executable = bundle.executableURL, let bundleID = bundle.bundleIdentifier,
              let team = try? PayloadNativeCode.teamID(executable), !team.isEmpty else { return nil }
        let docs = documents ?? ShellHostConfig.defaultAppDataRoot().deletingLastPathComponent()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let host = PayloadCapabilities(bundleID: bundleID, teamID: team,
                                       osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                                       executableSHA256: try? PayloadArchive.digest(executable))
        do {
            let store = try PayloadStore(documents: docs, host: host, metadataValidator: validateMetadata)
            if let error = store.startupWriteError { record("startup writes: \(error)") }
            return store
        }
        catch {
            try? FileManager.default.removeItem(at: docs.appendingPathComponent(PayloadCapabilities.fileName))
            record("store: \(String(describing: error))")
            return nil
        }
    }

    static func validateMetadata(_ framework: URL) throws {
        let entry = GameCatalogue.readFramework(at: framework)
        if let problem = entry.problem { throw PayloadError.invalid(problem.detail) }
    }

    static func record(_ message: String) {
        FileHandle.standardError.write(Data("shell: payload \(message)\n".utf8))
    }
}
