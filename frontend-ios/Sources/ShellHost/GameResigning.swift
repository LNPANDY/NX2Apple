import Foundation
import Darwin
import Observation

/// All windows share the same process and loaded images.
@MainActor @Observable final class GameSigningSession {
    static let shared = GameSigningSession()
    var resigning = false
    var attemptedLaunch = false

    private struct Window {
        weak var model: ShellHostModel?
    }
    private var windows: [Window] = []

    func register(_ model: ShellHostModel) {
        windows.removeAll { $0.model == nil }
        windows.append(Window(model: model))
    }

    func reload() {
        for window in windows { window.model?.reload() }
    }

    /// Preparation and cloud decisions reserve the process across every window.
    /// Weak references release the reservation when a window/model goes away.
    var hasPendingLaunch: Bool {
        windows.contains { window in
            guard let model = window.model else { return false }
            return model.launchingGame || model.cloudConflict != nil
        }
    }
}


/// Work only on a private sibling stage. Existing game bytes survive every signing failure.
enum GameResigning {
    static func isEligible(framework: URL, hotRoot: URL, titleID: String) -> Bool {
        framework.isFileURL && hotRoot.isFileURL && isTitleID(titleID.uppercased()) &&
            framework.pathExtension == "framework" &&
            framework.deletingLastPathComponent().standardizedFileURL == hotRoot.standardizedFileURL &&
            framework.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == hotRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    static func replace(framework: URL, hotRoot: URL, titleID: String,
                      sign: (URL) throws -> Void) throws {
        let fm = FileManager.default
        guard isEligible(framework: framework, hotRoot: hotRoot, titleID: titleID) else {
            throw ShellSigningError.invalid("only imported games can be re-signed")
        }
        // The catalogue supports imported frameworks with their own basenames.
        let expected = framework.lastPathComponent
        let originalIdentity = try directoryIdentity(framework)
        // Validate before copying too, so symlinks cannot pull other files into the stage.
        _ = try ShellFrameworkResigner.nativeFiles(framework: framework)
        // Only exact directories owned by this workflow. A previous interruption
        // cannot leave the installed path missing, so these copies are expendable.
        for old in try fm.contentsOfDirectory(at: hotRoot, includingPropertiesForKeys: nil) {
            let name = old.lastPathComponent
            guard name.hasPrefix(".resigning-") else { continue }
            let tail = String(name.dropFirst(".resigning-".count))
            guard tail.count == 53, tail.dropFirst(16).first == "-",
                  isTitleID(String(tail.prefix(16))), UUID(uuidString: String(tail.dropFirst(17))) != nil else { continue }
            try fm.removeItem(at: old)
        }
        let stage = hotRoot.appendingPathComponent(".resigning-" + titleID + "-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        var protectedStage = stage
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedStage.setResourceValues(values)
        let copy = stage.appendingPathComponent(expected)
        try fm.copyItem(at: framework, to: copy)
        try sign(copy)
        // Detect an external importer replacing the source while signing. This
        // is not a lock against external writers or in-place file mutations.
        guard try directoryIdentity(framework) == originalIdentity else {
            throw ShellSigningError.invalid("installed game changed while signing")
        }
        // The kernel has accepted every image. Atomic exchange is the commit
        // point: interruption leaves either the old or the complete signed copy.
        guard renameatx_np(AT_FDCWD, framework.path, AT_FDCWD, copy.path, UInt32(RENAME_SWAP)) == 0 else {
            throw ShellSigningError.invalid("cannot atomically install the signed game")
        }
        // The original now lives in stage and is removed by defer. A crash may
        // leave this hidden backup, but never an absent installed framework.
    }

    private static func directoryIdentity(_ url: URL) throws -> [UInt64] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw ShellSigningError.invalid("installed framework directory changed")
        }
        return [device.uint64Value, inode.uint64Value]
    }

}
