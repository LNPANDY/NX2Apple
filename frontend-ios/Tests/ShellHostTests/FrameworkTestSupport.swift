import Foundation
@testable import ShellHost

/// A temporary folder standing in for `<App>/Frameworks`, removed with the object. Only manifests, a launcher list and
/// empty files, never game data.
final class FrameworkBox: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shellhost-fw-\(UUID().uuidString)", isDirectory: true)
    var frameworks: URL { root.appendingPathComponent("Frameworks", isDirectory: true) }
    var documents: URL { root.appendingPathComponent("Documents", isDirectory: true) }
    var resources: URL { root.appendingPathComponent("App", isDirectory: true) }
    init() throws { try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }

    /// Makes `<folder>` with the orbit fixture's manifest (its `framework` and `title_id` replaced) and launcher list.
    @discardableResult func makeFramework(folder: String = "DmGame.framework", titleID: String = Fixtures.orbit, manifestFramework: String? = nil,
                                          launcherAt: String = "dm/launcher.json") throws -> URL {
        let fw = frameworks.appendingPathComponent(folder, isDirectory: true)
        let source = Fixtures.gamesURL.appendingPathComponent(Fixtures.orbit)
        var manifest = try String(contentsOf: source.appendingPathComponent("game.manifest.json"), encoding: .utf8)
        manifest = manifest.replacingOccurrences(of: Fixtures.orbit, with: titleID)
            .replacingOccurrences(of: "\"DmGame.framework\"", with: "\"\(manifestFramework ?? folder)\"")
        var launcher = try String(contentsOf: source.appendingPathComponent("launcher.json"), encoding: .utf8)
        launcher = launcher.replacingOccurrences(of: Fixtures.orbit, with: titleID)
        try write(manifest, to: fw.appendingPathComponent("game.manifest.json"))
        try write(launcher, to: fw.appendingPathComponent(launcherAt))
        return fw
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func makeFolder(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
}
