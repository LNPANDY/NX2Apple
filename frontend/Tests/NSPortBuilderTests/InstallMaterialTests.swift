import XCTest
@testable import NSPortBuilder

/// What a reinstall installs (the cached app, an IPA, or nothing) and what the phone says it still has: the pieces the
/// library's Reinstall row, the "not on the phone" state and the always-available re-sign are built from.
final class InstallMaterialTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-material-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }

    func testTheCachedAppWinsThenTheIPA() throws {
        let app = temporary.appendingPathComponent("DmIOS.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent("Info.plist"))
        let ipa = temporary.appendingPathComponent("Saved.ipa")
        try Data([0]).write(to: ipa)
        XCTAssertEqual(BuildModel.installMaterial(app: app.path, ipa: ipa.path), .app(app.path))
        XCTAssertEqual(BuildModel.installMaterial(app: app.path, ipa: ""), .app(app.path), "an app alone")
        XCTAssertEqual(BuildModel.installMaterial(app: temporary.appendingPathComponent("gone/DmIOS.app").path, ipa: ipa.path),
                       .ipa(ipa.path), "the build's app is gone: the saved IPA is what the phone can still take")
        XCTAssertEqual(BuildModel.installMaterial(app: temporary.appendingPathComponent("gone/DmIOS.app").path, ipa: ""), .none)
    }

    /// The list `devicectl device info apps --json-output -` writes: result.apps[].bundleIdentifier.
    func testTheDeviceAppListIsParsed() throws {
        let listed = #"{"info":{},"result":{"apps":[{"bundleIdentifier":"org.nxnative.a","name":"A"},{"bundleIdentifier":"org.nxnative.b"}]}}"#
        XCTAssertEqual(BuildModel.installedBundleIDs(fromDeviceInfoAppsJSON: Data(listed.utf8)),
                       ["org.nxnative.a", "org.nxnative.b"])
        XCTAssertEqual(BuildModel.installedBundleIDs(fromDeviceInfoAppsJSON: Data(#"{"result":{"apps":[]}}"#.utf8)), [],
                       "a device with no developer apps is an answer, not an unknown")
        XCTAssertNil(BuildModel.installedBundleIDs(fromDeviceInfoAppsJSON: Data(#"{"result":{}}"#.utf8)))
        XCTAssertNil(BuildModel.installedBundleIDs(fromDeviceInfoAppsJSON: Data("not json".utf8)))
        XCTAssertEqual(BuildModel.installedAppsArguments(device: "UDID"),
                       ["devicectl", "device", "info", "apps", "--device", "UDID", "--json-output", "-"])
    }

    /// nil until the phone has been read, then true/false: a row must not claim a game the player deleted.
    @MainActor func testWhetherThePhoneStillHasTheGame() {
        let model = BuildModel()
        XCTAssertNil(model.isOnDevice(bundle: "org.nxnative.a", device: "D"), "not read yet")
        XCTAssertNil(model.isOnDevice(bundle: "", device: "D"))
        model.deviceApps["D"] = ["org.nxnative.a"]
        XCTAssertEqual(model.isOnDevice(bundle: "org.nxnative.a", device: "D"), true)
        XCTAssertEqual(model.isOnDevice(bundle: "org.nxnative.gone", device: "D"), false)
        XCTAssertNil(model.isOnDevice(bundle: "org.nxnative.a", device: "OTHER"), "another device was not read")
    }
}
