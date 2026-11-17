import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel

@MainActor final class BuildCompletionTests: IsolatedDefaultsTestCase {
    func testArtifactsAloneAndRunningOperationsAreNotCompletion() {
        let build = LauncherStores(defaults: testDefaults).build
        build.macAppPath = "/fixture/Game.app"
        build.exportedIPAPath = "/fixture/Game.ipa"
        XCTAssertNil(build.completionStatus)
        build.done = true
        XCTAssertEqual(build.completionStatus, .exported)
        build.running = true
        XCTAssertNil(build.completionStatus)
        build.running = false; build.stoppedByPlayer = true
        XCTAssertNil(build.completionStatus)
    }

    func testMacAndExportRemainDistinctAndSingleGameUsesRecordedArtifact() {
        let stores = LauncherStores(defaults: testDefaults), build = stores.build
        build.runningTarget = BuildTarget.mac
        build.macAppPath = "/fixture/Game.app"; build.done = true
        XCTAssertEqual(build.completionStatus, .mac)
        build.exportedIPAPath = "/fixture/shared.ipa"
        stores.deviceStore.exportOneGame = true
        XCTAssertFalse(build.completedOneGameIPA)
        build.oneGameIPAPath = build.exportedIPAPath
        XCTAssertTrue(build.completedOneGameIPA)
        XCTAssertEqual(build.completionStatus, .exported)
    }

    func testFrameworkResultUsesTheRecordedArtifactAfterExportPreferencesChange() {
        let stores = LauncherStores(defaults: testDefaults), build = stores.build
        build.exportedIPAPath = "/fixture/Game.framework"; build.done = true
        stores.deviceStore.exportFramework = false
        stores.deviceStore.exportOneGame = true
        XCTAssertEqual(build.completionStatus, .exported)
        XCTAssertTrue(build.completedFramework)
        XCTAssertFalse(build.completedOneGameIPA)
        build.exportedIPAPath = "/fixture/Game.ipa"
        XCTAssertFalse(build.completedFramework)
    }

    func testSkippedDataRemainsActionableAndSuccessfulRetryCompletesIt() {
        let stores = LauncherStores(defaults: testDefaults), build = stores.build
        stores.deviceStore.installDevice = "device"
        build.installedOn = "device"; build.installedAppPath = "/fixture/Game.app"
        build.archivePath = "/fixture/0100000000000000"
        build.installedDataComplete = false; build.done = true
        XCTAssertEqual(build.completionStatus, .needsData)
        XCTAssertTrue(build.canSendToDevice)
        build.done = false; build.send = .sent(app: "Game")
        XCTAssertEqual(build.completionStatus, .installed)
        build.installedOn = "other-device"
        XCTAssertNil(build.installedDataComplete)
        XCTAssertNil(build.completionStatus)
    }

    func testSendingToAnotherDeviceDoesNotCompleteOriginalInstall() {
        let stores = LauncherStores(defaults: testDefaults), build = stores.build
        build.installedOn = "original"; build.installedDataComplete = false
        build.archivePath = "/fixture/0100000000000000"
        stores.deviceStore.installDevice = "other"
        build.send = .sent(app: "Game")
        XCTAssertEqual(build.completionStatus, .needsData)
        XCTAssertEqual(build.installedDataComplete, false)
    }
    func testLatestInstallWinsOverAnOlderExportArtifact() {
        let build = LauncherStores(defaults: testDefaults).build
        build.exportedIPAPath = "/fixture/older.ipa"
        build.completedOperation = .installing
        build.installedOn = "device"; build.installedDataComplete = true; build.done = true
        XCTAssertEqual(build.completionStatus, .installed)
        build.completedOperation = .exportingIPA
        XCTAssertEqual(build.completionStatus, .exported)
        build.done = false
        XCTAssertNil(build.completionStatus, "An older IPA must not hide a failed new export")
    }

}
