import CoreGraphics
import Foundation
import ImageIO
import ShellUI
import Testing
@testable import ShellHost

@MainActor
private final class DeepLinkHarness {
    var openedURLs: [URL] = []
    var copiedStrings: [String] = []
    var savedPhotos: [Data] = []
    var allowPhotoSave = true
    var activeGameID: String?
    var stopRequestCount = 0
}

private final class DeepLinkRecordingLauncher: GameLauncher, @unchecked Sendable {
    var launched: [LaunchableGame] = []
    var error: (any Error)?
    var onLaunch: (@MainActor (LaunchableGame) -> Void)?

    @MainActor func launch(_ game: LaunchableGame) async throws {
        launched.append(game)
        if let error { throw error }
        onLaunch?(game)
    }
}

private struct DeepLinkLaunchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

@MainActor @Suite(.serialized) struct DeepLinkRouterTests {
    private let secondTitleID = "0100000000080000"

    private func writePlist(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func makePlayableFramework(in root: URL, folder: String, titleID: String, title: String,
                                       bundleID: String, box: FrameworkBox) throws -> URL {
        let fw = try box.makeFramework(folder: folder, titleID: titleID, launcherAt: "dm/launcher.json")
        let manifestURL = fw.appendingPathComponent("game.manifest.json")
        var manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        manifest = manifest.replacingOccurrences(of: "\"Orbit Fixture\"", with: "\"\(title)\"")
        try Data(manifest.utf8).write(to: manifestURL)

        let mslFile = fw.appendingPathComponent("msl/b-3f9a2c/fixture.metallib")
        try box.write("fixture", to: mslFile)

        try writePlist([
            "CFBundleIdentifier": bundleID,
            "CFBundleDisplayName": title,
            "CFBundleShortVersionString": "1.2.3",
            "DMTitleID": titleID,
            "CFBundleIconFile": "AppIcon.png"
        ], to: fw.appendingPathComponent("Info.plist"))

        let iconURL = fw.appendingPathComponent("AppIcon.png")
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        try pngData(width: 64, height: 64).write(to: iconURL)
        return fw
    }

    private func seedAppData(box: FrameworkBox, titleID: String) throws {
        let romfsDir = box.documents.appendingPathComponent("games/\(titleID)/romfs", isDirectory: true)
        try box.write("", to: romfsDir.appendingPathComponent("fixture.marker"))
    }

    private func makeModel(box: FrameworkBox, hotRoot: URL? = nil, harness: DeepLinkHarness = DeepLinkHarness(),
                           launcher: DeepLinkRecordingLauncher = DeepLinkRecordingLauncher(),
                           suitePrefix: String = "deeplink.tests.\(UUID().uuidString).") -> ShellHostModel {
        let config = ShellHostConfig(
            gamesRoot: box.frameworks,
            appDataRoot: box.documents.appendingPathComponent("games", isDirectory: true),
            hotFrameworksRoot: hotRoot,
            environment: HostEnvironment(chain: "b-3f9a2c"),
            defaults: { UserDefaults(suiteName: suitePrefix + $0)! },
            openURL: { harness.openedURLs.append($0) },
            copyToPasteboard: { harness.copiedStrings.append($0) },
            saveImageToPhotos: { data in
                guard harness.allowPhotoSave else { return false }
                harness.savedPhotos.append(data)
                return true
            },
            activeRunningGameID: { harness.activeGameID },
            requestStopRunningGame: { harness.stopRequestCount += 1 }
        )
        let shell = ShellSettingsStore(defaults: UserDefaults(suiteName: suitePrefix + "shell")!)
        return ShellHostModel(config: config, launcher: launcher, shellSettings: shell)
    }

    @Test func parsesQueryAndShorthandFormatsWithValidatedCallbacks() throws {
        let queryURL = try #require(URL(string: "nx2apple://launch?id=DmGame01007EF00011E000&x-success=shortcuts%3A%2F%2F&x-error=shortcuts%3A%2F%2Fx-error"))
        let req1 = try #require(DeepLinkRouter.parse(queryURL))
        #expect(req1.target == "DmGame01007EF00011E000")
        #expect(req1.successURL == URL(string: "shortcuts://"))
        #expect(req1.errorURL == URL(string: "shortcuts://x-error"))

        let shortURL = try #require(URL(string: "nx2apple://launch/Orbit%20Fixture?x-success=shortcuts://callback"))
        let req2 = try #require(DeepLinkRouter.parse(shortURL))
        #expect(req2.target == "Orbit Fixture")
        #expect(req2.successURL == URL(string: "shortcuts://callback"))
        #expect(req2.errorURL == nil)

        #expect(DeepLinkRouter.parse(try #require(URL(string: "nx2apple://unknown?id=foo"))) == nil)
        #expect(DeepLinkRouter.parse(try #require(URL(string: "nx2apple://launch"))) == nil)
        #expect(DeepLinkRouter.parse(try #require(URL(string: "nx2apple://launch/a/b"))) == nil)
    }

    @Test func rejectsDangerousAndRecursiveCallbackSchemesAndAppendsErrorMessage() throws {
        let rejected = [
            "javascript:alert(1)",
            "JavaScript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "file:///etc/passwd",
            "http://example.com/cb",
            "https://example.com/cb",
            "about:blank",
            "blob:https://example.com/uuid",
            "vbscript:msgbox(1)",
            "nx2apple://launch?id=Orbit",
            "NX2APPLE://launch?id=Orbit",
            "123bad://callback",
            "/relative/path",
            "shortcuts://bad\ncallback"
        ]
        for raw in rejected {
            #expect(DeepLinkRouter.validatedCallbackURL(raw) == nil, "Expected \(raw) to be rejected")
        }

        #expect(DeepLinkRouter.validatedCallbackURL("shortcuts://") == URL(string: "shortcuts://"))
        #expect(DeepLinkRouter.validatedCallbackURL("shortcuts://x-callback-url/success") == URL(string: "shortcuts://x-callback-url/success"))
        #expect(DeepLinkRouter.validatedCallbackURL("my-app+1.0://done") == URL(string: "my-app+1.0://done"))

        let base = try #require(URL(string: "shortcuts://x-callback-url/error?step=1"))
        let errURL = DeepLinkRouter.errorCallbackURL(base: base, message: "Game missing & broken")
        let comps = try #require(URLComponents(url: errURL, resolvingAgainstBaseURL: false))
        #expect(comps.queryItems?.first(where: { $0.name == "step" })?.value == "1")
        #expect(comps.queryItems?.first(where: { $0.name == "errorMessage" })?.value == "Game missing & broken")
    }

    @Test func matchesFourTiersCaseInsensitivelyWithHotOverridePriority() throws {
        let box = try FrameworkBox()
        let hotRoot = box.root.appendingPathComponent("Documents/Frameworks", isDirectory: true)
        let bundledFW = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(Fixtures.orbit).framework", titleID: Fixtures.orbit,
            title: "Orbit Fixture", bundleID: "org.nxnative.orbit", box: box
        )
        let hotFW = try makePlayableFramework(
            in: hotRoot, folder: "DmGame\(Fixtures.orbit).framework", titleID: Fixtures.orbit,
            title: "Orbit Hot", bundleID: "org.nxnative.orbit.hot", box: box
        )
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(secondTitleID).framework", titleID: secondTitleID,
            title: "Second Game", bundleID: "org.nxnative.second", box: box
        )
        // Force hot override to be newer than bundled.
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: bundledFW.appendingPathComponent("game.manifest.json").path)

        let entries = GameCatalogue.scan(root: box.frameworks, hotRoot: hotRoot, gameDataRoot: box.documents.appendingPathComponent("games"))
        #expect(entries.count == 2)

        // Tier 1: .framework name (with or without .framework suffix, case-insensitive) and hot override wins.
        let t1a = try #require(DeepLinkRouter.matchEntry(target: "dmgame\(Fixtures.orbit.lowercased())", in: entries))
        #expect(t1a.directory.path == hotFW.path)
        let t1b = try #require(DeepLinkRouter.matchEntry(target: "DMGAME\(Fixtures.orbit).FRAMEWORK", in: entries))
        #expect(t1b.directory.path == hotFW.path)

        // Tier 2: CFBundleIdentifier
        let t2 = try #require(DeepLinkRouter.matchEntry(target: "ORG.NXNATIVE.SECOND", in: entries))
        #expect(t2.id == secondTitleID)

        // Tier 3: Title ID
        let t3 = try #require(DeepLinkRouter.matchEntry(target: secondTitleID.lowercased(), in: entries))
        #expect(t3.id == secondTitleID)

        // Tier 4: Display name / manifest name
        let t4 = try #require(DeepLinkRouter.matchEntry(target: "second game", in: entries))
        #expect(t4.id == secondTitleID)

        #expect(DeepLinkRouter.shortcutURLString(for: t1a) == "nx2apple://launch?id=DmGame\(Fixtures.orbit)")
    }

    @Test func parsesFrameworkInfoPlistAndResolvesIconsSafely() throws {
        let box = try FrameworkBox()
        let fw = try box.makeFramework(folder: "DmGame\(Fixtures.orbit).framework", titleID: Fixtures.orbit)
        try writePlist([
            "CFBundleIdentifier": "org.nxnative.custom",
            "CFBundleDisplayName": "Custom Display Name",
            "CFBundleShortVersionString": "2.0.1",
            "DMTitleID": Fixtures.orbit,
            "CFBundleIconFile": "../secret.png"
        ], to: fw.appendingPathComponent("Info.plist"))
        try pngData(width: 32, height: 32).write(to: fw.appendingPathComponent("AppIcon.png"))
        try pngData(width: 16, height: 16).write(to: fw.appendingPathComponent("icon.png"))

        // Corrupt manifest name fallback -> readableName falls back to Info.plist displayName, and traversal iconFile falls back to AppIcon.png.
        try box.write("{", to: fw.appendingPathComponent("game.manifest.json"))
        let brokenEntry = GameCatalogue.readFramework(at: fw)
        #expect(brokenEntry.bundleInfo?.bundleIdentifier == "org.nxnative.custom")
        #expect(brokenEntry.bundleInfo?.shortVersionString == "2.0.1")
        #expect(brokenEntry.bundleInfo?.titleID == Fixtures.orbit)
        #expect(brokenEntry.readableName == "Custom Display Name")
        #expect(brokenEntry.iconURL?.lastPathComponent == "AppIcon.png")
        #expect(brokenEntry.shortcutFrameworkIdentifier == "DmGame\(Fixtures.orbit)")

        // Reject colon and slash traversal too, falling back to icon.png when AppIcon is absent.
        try FileManager.default.removeItem(at: fw.appendingPathComponent("AppIcon.png"))
        try writePlist([
            "CFBundleIconFile": "sub/icon.png"
        ], to: fw.appendingPathComponent("Info.plist"))
        let iconFallback = GameCatalogue.readFramework(at: fw)
        #expect(iconFallback.iconURL?.lastPathComponent == "icon.png")

        // Valid single-component iconFile wins over AppIcon.png.
        try pngData(width: 32, height: 32).write(to: fw.appendingPathComponent("AppIcon.png"))
        try pngData(width: 32, height: 32).write(to: fw.appendingPathComponent("CustomIcon.png"))
        try writePlist([
            "CFBundleIconFile": "CustomIcon.png"
        ], to: fw.appendingPathComponent("Info.plist"))
        let customIconEntry = GameCatalogue.readFramework(at: fw)
        #expect(customIconEntry.iconURL?.lastPathComponent == "CustomIcon.png")
    }

    @Test func coldLaunchBlackOverlayAndErrorCallbacks() async throws {
        let box = try FrameworkBox()
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(Fixtures.orbit).framework", titleID: Fixtures.orbit,
            title: "Orbit Fixture", bundleID: "org.nxnative.orbit", box: box
        )
        try seedAppData(box: box, titleID: Fixtures.orbit)

        // Success cold launch: isDeepLinkLaunching becomes true synchronously on handleDeepLink, then clears after launch.
        let harness1 = DeepLinkHarness()
        let launcher1 = DeepLinkRecordingLauncher()
        let model1 = makeModel(box: box, harness: harness1, launcher: launcher1)
        let url1 = try #require(URL(string: "nx2apple://launch?id=DmGame\(Fixtures.orbit)&x-success=shortcuts://"))
        #expect(model1.handleDeepLink(url1))
        #expect(model1.isDeepLinkLaunching == true)
        await model1.waitForDeepLinkTask()
        #expect(launcher1.launched.map(\.titleID) == [Fixtures.orbit])
        #expect(model1.isDeepLinkLaunching == false)

        // Missing target -> exits black overlay and calls x-error with errorMessage.
        let harness2 = DeepLinkHarness()
        let model2 = makeModel(box: box, harness: harness2)
        let urlMissing = try #require(URL(string: "nx2apple://launch?id=MissingGame&x-error=shortcuts://x-error"))
        #expect(await model2.handleDeepLinkNow(urlMissing))
        #expect(model2.isDeepLinkLaunching == false)
        #expect(harness2.openedURLs.count == 1)
        let missingComps = try #require(URLComponents(url: harness2.openedURLs[0], resolvingAgainstBaseURL: false))
        #expect(missingComps.scheme == "shortcuts")
        #expect((missingComps.queryItems?.first(where: { $0.name == "errorMessage" })?.value ?? "").isEmpty == false)

        // Unplayable (needs game data) without x-error -> exits black overlay and populates model.notice.
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(secondTitleID).framework", titleID: secondTitleID,
            title: "Quiet Fixture", bundleID: "org.nxnative.quiet", box: box
        )
        let harness3 = DeepLinkHarness()
        let model3 = makeModel(box: box, harness: harness3)
        let urlUnplayable = try #require(URL(string: "nx2apple://launch/\(secondTitleID)"))
        #expect(await model3.handleDeepLinkNow(urlUnplayable))
        #expect(model3.isDeepLinkLaunching == false)
        #expect(harness3.openedURLs.isEmpty)
        #expect(model3.notice != nil)

        // Launcher failure -> exits black overlay and calls x-error with errorMessage.
        let harness4 = DeepLinkHarness()
        let failingLauncher = DeepLinkRecordingLauncher()
        failingLauncher.error = DeepLinkLaunchError(message: "Signature failed")
        let model4 = makeModel(box: box, harness: harness4, launcher: failingLauncher)
        let urlFail = try #require(URL(string: "nx2apple://launch?id=\(Fixtures.orbit)&x-error=shortcuts://err"))
        #expect(await model4.handleDeepLinkNow(urlFail))
        #expect(model4.isDeepLinkLaunching == false)
        #expect(harness4.openedURLs.count == 1)
        let failComps = try #require(URLComponents(url: harness4.openedURLs[0], resolvingAgainstBaseURL: false))
        #expect(failComps.queryItems?.first(where: { $0.name == "errorMessage" })?.value == "Signature failed")
    }

    @Test func sameGameForegroundUpdatesCallbacksAndQuitTriggersXSuccess() async throws {
        let box = try FrameworkBox()
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(Fixtures.orbit).framework", titleID: Fixtures.orbit,
            title: "Orbit Fixture", bundleID: "org.nxnative.orbit", box: box
        )
        try seedAppData(box: box, titleID: Fixtures.orbit)

        let harness = DeepLinkHarness()
        let launcher = DeepLinkRecordingLauncher()
        launcher.onLaunch = { game in harness.activeGameID = game.titleID }
        let model = makeModel(box: box, harness: harness, launcher: launcher)

        let firstURL = try #require(URL(string: "nx2apple://launch?id=\(Fixtures.orbit)&x-success=shortcuts://first"))
        #expect(await model.handleDeepLinkNow(firstURL))
        #expect(launcher.launched.count == 1)
        #expect(harness.activeGameID == Fixtures.orbit)

        // Re-invoking for the same running game keeps foreground, does not stop or relaunch, and updates pending callback.
        let secondURL = try #require(URL(string: "nx2apple://launch?id=\(Fixtures.orbit)&x-success=shortcuts://second"))
        #expect(await model.handleDeepLinkNow(secondURL))
        #expect(model.isDeepLinkLaunching == false)
        #expect(harness.stopRequestCount == 0)
        #expect(launcher.launched.count == 1)

        // Normal game quit via DMShellDidReturnToLibrary clears state first and opens updated shortcuts:// callback once.
        harness.activeGameID = nil
        NotificationCenter.default.post(name: ShellHostModel.didReturnToLibraryNotification, object: nil)
        #expect(harness.openedURLs == [try #require(URL(string: "shortcuts://second"))])

        NotificationCenter.default.post(name: ShellHostModel.didReturnToLibraryNotification, object: nil)
        #expect(harness.openedURLs.count == 1, "Pending x-success must be cleared before calling openURL")
    }

    @Test func crossGameSwitchSuppressesOldXSuccessAndLaunchesQueuedTargetOnReturn() async throws {
        let box = try FrameworkBox()
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(Fixtures.orbit).framework", titleID: Fixtures.orbit,
            title: "Orbit Fixture", bundleID: "org.nxnative.orbit", box: box
        )
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(secondTitleID).framework", titleID: secondTitleID,
            title: "Second Game", bundleID: "org.nxnative.second", box: box
        )
        try seedAppData(box: box, titleID: Fixtures.orbit)
        try seedAppData(box: box, titleID: secondTitleID)

        let harness = DeepLinkHarness()
        let launcher = DeepLinkRecordingLauncher()
        launcher.onLaunch = { game in harness.activeGameID = game.titleID }
        let model = makeModel(box: box, harness: harness, launcher: launcher)

        // Launch Game A with x-success=shortcuts://game-a
        let urlA = try #require(URL(string: "nx2apple://launch?id=\(Fixtures.orbit)&x-success=shortcuts://game-a"))
        #expect(await model.handleDeepLinkNow(urlA))
        #expect(harness.activeGameID == Fixtures.orbit)

        // While Game A is running, open Game B with x-success=shortcuts://game-b
        let urlB = try #require(URL(string: "nx2apple://launch?id=\(secondTitleID)&x-success=shortcuts://game-b"))
        #expect(await model.handleDeepLinkNow(urlB))
        #expect(model.isDeepLinkLaunching == true)
        #expect(harness.stopRequestCount == 1)
        #expect(harness.openedURLs.isEmpty, "Old x-success must be cleared when switching games")

        // Game A returns to library -> queued Game B starts immediately without opening shortcuts://game-a.
        harness.activeGameID = nil
        NotificationCenter.default.post(name: ShellHostModel.didReturnToLibraryNotification, object: nil)
        await model.waitForDeepLinkTask()
        #expect(harness.openedURLs.isEmpty)
        #expect(launcher.launched.map(\.titleID) == [Fixtures.orbit, secondTitleID])
        #expect(harness.activeGameID == secondTitleID)

        // Game B quits -> opens shortcuts://game-b.
        harness.activeGameID = nil
        NotificationCenter.default.post(name: ShellHostModel.didReturnToLibraryNotification, object: nil)
        #expect(harness.openedURLs == [try #require(URL(string: "shortcuts://game-b"))])
    }

    @Test func deepLinkWhileStoppingQueuesInsteadOfReusingAndUnknownTargetPreservesRunningCallback() async throws {
        let box = try FrameworkBox()
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(Fixtures.orbit).framework", titleID: Fixtures.orbit,
            title: "Orbit Fixture", bundleID: "org.nxnative.orbit", box: box
        )
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(secondTitleID).framework", titleID: secondTitleID,
            title: "Second Game", bundleID: "org.nxnative.second", box: box
        )
        try seedAppData(box: box, titleID: Fixtures.orbit)
        try seedAppData(box: box, titleID: secondTitleID)

        let harness = DeepLinkHarness()
        let launcher = DeepLinkRecordingLauncher()
        launcher.onLaunch = { game in harness.activeGameID = game.titleID }
        let model = makeModel(box: box, harness: harness, launcher: launcher)

        // Start Game A with x-success callback.
        let urlA = try #require(URL(string: "nx2apple://launch?id=\(Fixtures.orbit)&x-success=shortcuts://done-a"))
        #expect(await model.handleDeepLinkNow(urlA))
        #expect(harness.activeGameID == Fixtures.orbit)

        // Sending an unknown target while Game A is still running triggers error callback for that bad link
        // without wiping Game A's pending x-success callback.
        let badURL = try #require(URL(string: "nx2apple://launch?id=MissingGame&x-error=shortcuts://err-bad"))
        #expect(await model.handleDeepLinkNow(badURL))
        #expect(harness.openedURLs == [try #require(URL(string: "shortcuts://err-bad?errorMessage=Game%20%22MissingGame%22%20was%20not%20found."))])
        harness.openedURLs.removeAll()

        // Request switch to Game B (async stop requested, activeGameID still reports A until teardown finishes).
        let urlB = try #require(URL(string: "nx2apple://launch?id=\(secondTitleID)&x-success=shortcuts://done-b"))
        #expect(await model.handleDeepLinkNow(urlB))
        #expect(harness.stopRequestCount == 1)

        // Before Game A finishes tearing down, re-requesting A must queue A for relaunch rather than treating it as already running.
        let relaunchA = try #require(URL(string: "nx2apple://launch?id=\(Fixtures.orbit)&x-success=shortcuts://relaunch-a"))
        #expect(await model.handleDeepLinkNow(relaunchA))
        #expect(harness.openedURLs.isEmpty)
        #expect(model.isDeepLinkLaunching)

        // When Game A finishes teardown, ShellHostModel launches queued A rather than firing x-success prematurely.
        harness.activeGameID = nil
        NotificationCenter.default.post(name: ShellHostModel.didReturnToLibraryNotification, object: nil)
        try await Task.sleep(for: .milliseconds(80))
        await model.waitForDeepLinkTask()
        #expect(launcher.launched.map(\.titleID) == [Fixtures.orbit, Fixtures.orbit])
        #expect(harness.openedURLs.isEmpty)

        // When Game A finally exits normally, shortcuts://relaunch-a fires.
        NotificationCenter.default.post(name: ShellHostModel.didReturnToLibraryNotification, object: nil)
        #expect(harness.openedURLs == [try #require(URL(string: "shortcuts://relaunch-a"))])
    }

    @Test func hotAddedFrameworkLaunchesWithoutPriorReloadAndManualPlayClearsDeepLinkState() async throws {
        let box = try FrameworkBox()
        let hotRoot = box.documents.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: hotRoot, withIntermediateDirectories: true)

        let harness = DeepLinkHarness()
        let launcher = DeepLinkRecordingLauncher()
        let model = makeModel(box: box, hotRoot: hotRoot, harness: harness, launcher: launcher)
        #expect(model.details.isEmpty)

        // Add a hot framework after model construction without calling reload().
        _ = try makePlayableFramework(
            in: hotRoot, folder: "DmGame\(Fixtures.orbit).framework", titleID: Fixtures.orbit,
            title: "Hot Orbit", bundleID: "org.nxnative.hotorbit", box: box
        )
        try seedAppData(box: box, titleID: Fixtures.orbit)

        let hotURL = try #require(URL(string: "nx2apple://launch?id=org.nxnative.hotorbit&x-success=shortcuts://hot"))
        #expect(await model.handleDeepLinkNow(hotURL))
        #expect(model.isDeepLinkLaunching == false)
        #expect(launcher.launched.map(\.titleID) == [Fixtures.orbit])

        // Manual play clears pending deep link state so returning later does not trigger stale x-success.
        await model.playNow(Fixtures.orbit)
        #expect(launcher.launched.count == 2)
        NotificationCenter.default.post(name: ShellHostModel.didReturnToLibraryNotification, object: nil)
        #expect(harness.openedURLs.isEmpty)
    }

    @Test func copyShortcutURLActionCopiesCanonicalURL() throws {
        let box = try FrameworkBox()
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(Fixtures.orbit).framework", titleID: Fixtures.orbit,
            title: "Orbit Fixture", bundleID: "org.nxnative.orbit", box: box
        )
        let harness = DeepLinkHarness()
        let model = makeModel(box: box, harness: harness)
        let onCopy = try #require(model.actions.onCopyShortcutURL)
        onCopy(Fixtures.orbit)
        #expect(harness.copiedStrings == ["nx2apple://launch?id=DmGame\(Fixtures.orbit)"])
    }

    @Test func saveIconAndOpenShortcutsRendersOpaqueSquarePNGAndRespectsPhotoReceipt() async throws {
        let box = try FrameworkBox()
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(Fixtures.orbit).framework", titleID: Fixtures.orbit,
            title: "Orbit Fixture", bundleID: "org.nxnative.orbit", box: box
        )
        let harness = DeepLinkHarness()
        let model = makeModel(box: box, harness: harness)
        let onAdd = try #require(model.actions.onAddToHomeScreen)

        let ok = await onAdd(Fixtures.orbit)
        #expect(ok == true)
        #expect(harness.copiedStrings == ["Orbit Fixture"])
        #expect(harness.openedURLs == [HomeScreenShortcutSupport.createShortcutURL])
        #expect(harness.savedPhotos.count == 1)

        let savedPNG = try #require(harness.savedPhotos.first)
        let src = try #require(CGImageSourceCreateWithData(savedPNG as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(img.width == 512)
        #expect(img.height == 512)
        let opaqueAlpha: Set<CGImageAlphaInfo> = [.none, .noneSkipLast, .noneSkipFirst]
        #expect(opaqueAlpha.contains(img.alphaInfo))

        // Placeholder fallback when neither icon nor banner exists also produces a valid 512x512 opaque PNG.
        let placeholderPNG = try #require(
            HomeScreenShortcutSupport.renderSquareIconPNG(title: "The Legend of Zelda", seed: Fixtures.orbit, size: 512)
        )
        let phSrc = try #require(CGImageSourceCreateWithData(placeholderPNG as CFData, nil))
        let phImg = try #require(CGImageSourceCreateImageAtIndex(phSrc, 0, nil))
        #expect(phImg.width == 512 && phImg.height == 512)
        #expect(opaqueAlpha.contains(phImg.alphaInfo))

        // Negative receipt check: when photo library access is denied, do not open Shortcuts or claim success.
        harness.allowPhotoSave = false
        harness.openedURLs.removeAll()
        harness.copiedStrings.removeAll()
        let denied = await onAdd(Fixtures.orbit)
        #expect(denied == false)
        #expect(harness.copiedStrings == ["Orbit Fixture"])
        #expect(harness.openedURLs.isEmpty)
    }

    @Test func photoLibrarySaveExecutesChangeBlockAndCompletionOnBackgroundQueuesWithoutMainActorTrap() async throws {
        let box = try FrameworkBox()
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(Fixtures.orbit).framework", titleID: Fixtures.orbit,
            title: "Orbit Fixture", bundleID: "org.nxnative.orbit", box: box
        )
        let bgChangeQueue = DispatchQueue(label: "test.photokit.changeBlock")
        let bgCompletionQueue = DispatchQueue(label: "test.photokit.completion")
        let recorded = LockedBox<[Data]>([])
        let ranOffMain = LockedBox<Bool>(false)
        let suitePrefix = "shortcut.bg.\(UUID().uuidString)."

        let harness = DeepLinkHarness()
        let cfg = ShellHostConfig(
            gamesRoot: box.frameworks,
            appDataRoot: box.documents.appendingPathComponent("games", isDirectory: true),
            defaults: { UserDefaults(suiteName: suitePrefix + $0)! },
            openURL: { harness.openedURLs.append($0) },
            copyToPasteboard: { harness.copiedStrings.append($0) },
            saveImageToPhotos: { pngData in
                await PhotoLibraryImageSaver.savePNGData(
                    pngData,
                    requestAccess: {
                        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                            bgCompletionQueue.async { cont.resume(returning: true) }
                        }
                    },
                    performChanges: { changeBlock, completion in
                        bgChangeQueue.async {
                            dispatchPrecondition(condition: .notOnQueue(.main))
                            ranOffMain.withLock { $0 = !Thread.isMainThread }
                            changeBlock()
                            bgCompletionQueue.async {
                                dispatchPrecondition(condition: .notOnQueue(.main))
                                completion(true, nil)
                                // Duplicate completion callback must be ignored safely without double-resuming continuation.
                                completion(true, nil)
                            }
                        }
                    },
                    writeAsset: { data in
                        dispatchPrecondition(condition: .notOnQueue(.main))
                        recorded.withLock { $0.append(data) }
                    }
                )
            }
        )
        let model = ShellHostModel(config: cfg)
        let ok = await model.saveIconAndOpenShortcuts(for: Fixtures.orbit)
        #expect(ok == true)
        #expect(ranOffMain.withLock { $0 } == true)
        #expect(recorded.withLock { $0.count } == 1)
        #expect(harness.copiedStrings == ["Orbit Fixture"])
        #expect(harness.openedURLs == [HomeScreenShortcutSupport.createShortcutURL])

        // Error from PhotoKit background completion returns false and never opens Shortcuts.
        let failed = await PhotoLibraryImageSaver.savePNGData(
            Data([0x89, 0x50, 0x4E, 0x47]),
            requestAccess: { true },
            performChanges: { changeBlock, completion in
                bgChangeQueue.async {
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    changeBlock()
                    bgCompletionQueue.async {
                        completion(false, DeepLinkLaunchError(message: "PhotoKit write failed"))
                    }
                }
            },
            writeAsset: { _ in dispatchPrecondition(condition: .notOnQueue(.main)) }
        )
        #expect(failed == false)
    }

    @Test func availableShortcutGamesListsInstalledAndExcludesDeleted() throws {
        let box = try FrameworkBox()
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(Fixtures.orbit).framework", titleID: Fixtures.orbit,
            title: "Orbit Fixture", bundleID: "org.nxnative.orbit", box: box
        )
        _ = try makePlayableFramework(
            in: box.frameworks, folder: "DmGame\(secondTitleID).framework", titleID: secondTitleID,
            title: "Alpha Fixture", bundleID: "org.nxnative.alpha", box: box
        )
        let suitePrefix = "shortcut.catalog.\(UUID().uuidString)."
        let defaultsFn: @Sendable (String) -> UserDefaults = { UserDefaults(suiteName: suitePrefix + $0)! }

        let all = HomeScreenShortcutSupport.availableGames(
            gamesRoot: box.frameworks,
            defaults: defaultsFn
        )
        #expect(all.map(\.title) == ["Alpha Fixture", "Orbit Fixture"])
        #expect(all.allSatisfy { $0.iconPNG != nil })

        // Mark Orbit as deleted in shell defaults: Shortcuts entity query must exclude it.
        defaultsFn(Fixtures.orbit).set(true, forKey: GameDeletion.deletedKey)
        let filtered = HomeScreenShortcutSupport.availableGames(
            gamesRoot: box.frameworks,
            defaults: defaultsFn
        )
        #expect(filtered.map(\.titleID) == [secondTitleID])
    }

    @Test func projectShellYmlDeclaresURLSchemeAndFilesVisibility() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let yml = try String(contentsOf: iosRoot.appendingPathComponent("Shell/project-shell.yml"), encoding: .utf8)
        #expect(yml.contains("UIFileSharingEnabled: true"))
        #expect(yml.contains("LSSupportsOpeningDocumentsInPlace: true"))
        #expect(yml.contains("NSPhotoLibraryAddUsageDescription:"))
        #expect(yml.contains("CFBundleURLTypes:"))
        #expect(yml.contains("CFBundleURLName: org.nxnative.shell"))
        #expect(yml.contains("CFBundleURLRole: Editor"))
        #expect(yml.contains("CFBundleURLSchemes:"))
        #expect(yml.contains("- nx2apple"))

        let intentsSource = try String(contentsOf: iosRoot.appendingPathComponent("Shell/App/ShellShortcuts.swift"), encoding: .utf8)
        #expect(intentsSource.contains("struct LaunchGameIntent: AppIntent"))
        #expect(intentsSource.contains("struct ShellShortcutsProvider: AppShortcutsProvider"))
    }
}
