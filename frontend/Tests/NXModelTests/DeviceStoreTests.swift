import XCTest
@testable import NXModel
@testable import NXCore

/// `DeviceStore` without SwiftUI: the listings are closures that answer from the test and the defaults are a suite of their own.
/// Nothing reaches devicectl or the keychain of this Mac. The copy question is answered from the test the way the card does it.
@MainActor final class DeviceStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private let runner = FakeProcessRunner()
    private let phone = AppleDevice(id: "UDID-1", name: "Jo's iPhone", model: "iPhone 17", os: "27.0", reachable: true, transport: "wired")
    private let laptopTeam = SigningTeam(id: "ABCDE12345", identity: "Apple Development: Jo Doe (ABCDE12345)")
    private let freeTeam = SigningTeam(id: "FGHIJ67890", identity: "", name: "Jo Doe", personal: true)

    override func setUpWithError() throws {
        suite = "nxmodel-device-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore(devices: [AppleDevice]? = nil, teams: [SigningTeam]? = nil, xcrun: String = "/fake/xcrun") -> DeviceStore {
        let devices = devices ?? [phone], teams = teams ?? [laptopTeam, freeTeam]
        return DeviceStore(runner: runner, xcrun: xcrun, defaults: defaults, listDevices: { _ in devices }, readTeams: { teams })
    }

    private func plan() -> ShellCopyPlan {
        ShellCopyPlan(files: 2, bytes: 15_000_000_000, connection: .network, deviceName: "Jo's iPhone", sizeText: "15.0 GB in 2 files.", connectionText: "Wi-Fi")
    }

    // MARK: Devices and teams

    func testItStartsUnchecked() {
        let store = makeStore()
        XCTAssertEqual(store.devices, [])
        XCTAssertEqual(store.teams, [])
        XCTAssertFalse(store.checked)
        XCTAssertEqual(store.installDevice, "")
        XCTAssertEqual(store.signingTeam, "")
        XCTAssertNil(store.shellCopy)
        XCTAssertFalse(store.shellWaiting)
    }

    func testRefreshReadsDevicesAndTeamsAndMarksTheListingChecked() async {
        let store = makeStore()
        await store.refresh().value
        XCTAssertEqual(store.devices, [phone])
        XCTAssertEqual(store.teams, [laptopTeam, freeTeam])
        XCTAssertTrue(store.checked)
    }

    func testRefreshGivesTheListingTheXcrunItWasCreatedWith() async {
        final class Seen: @unchecked Sendable { var xcrun = "" }
        let seen = Seen()
        let store = DeviceStore(runner: runner, xcrun: "/stand/in/xcrun", defaults: defaults,
                                listDevices: { seen.xcrun = $0; return [] }, readTeams: { [] })
        XCTAssertEqual(store.xcrun, "/stand/in/xcrun")
        await store.refresh().value
        XCTAssertEqual(seen.xcrun, "/stand/in/xcrun")
    }

    func testARefreshKeepsTheChosenTeamWhenTheMacStillKnowsIt() async {
        let store = makeStore()
        store.signingTeam = freeTeam.id
        await store.refresh().value
        XCTAssertEqual(store.signingTeam, freeTeam.id)
    }

    func testARefreshReplacesATeamTheMacNoLongerKnowsWithTheFirstOne() async {
        let store = makeStore()
        store.signingTeam = "GONE000000"
        await store.refresh().value
        XCTAssertEqual(store.signingTeam, laptopTeam.id)
        let none = makeStore(teams: [])
        none.signingTeam = freeTeam.id
        await none.refresh().value
        XCTAssertEqual(none.signingTeam, "", "no team at all clears it")
    }

    func testTheChosenDeviceAndTeamAreSavedAndComeBack() {
        let store = makeStore()
        store.installDevice = "UDID-1"
        store.signingTeam = "ABCDE12345"
        XCTAssertEqual(defaults.string(forKey: DeviceStore.deviceKey), "UDID-1")
        XCTAssertEqual(defaults.string(forKey: DeviceStore.teamKey), "ABCDE12345")
        let again = makeStore()
        XCTAssertEqual(again.installDevice, "UDID-1")
        XCTAssertEqual(again.signingTeam, "ABCDE12345")
    }

    func testADeviceNameFallsBackToIPhoneForOneThatIsNotListed() async {
        let store = makeStore()
        XCTAssertEqual(store.deviceName("UDID-1"), "iPhone")
        await store.refresh().value
        XCTAssertEqual(store.deviceName("UDID-1"), "Jo's iPhone")
        XCTAssertEqual(store.deviceName("other"), "iPhone")
    }

    func testTheTeamsReaderCanBeChangedForALaterRead() {
        let store = makeStore()
        store.readTeams = { [] }
        XCTAssertEqual(store.readTeams(), [])
    }

    func testTheDefaultListingsGoThroughTheRunner() async {
        let store = DeviceStore(runner: runner, xcrun: "/fake/xcrun", defaults: defaults)
        runner.answer = { _ in ProcessResult(status: 1) }
        await store.refresh().value
        XCTAssertTrue(store.checked)
        XCTAssertEqual(store.devices, [])
        XCTAssertTrue(runner.commands.contains { $0.hasPrefix("xcrun devicectl list devices") }, "devicectl was asked through the runner: \(runner.commands)")
    }

    // MARK: The copy flow

    /// Asks the question the way the install does: from a background queue, which waits for the answer.
    private func ask(_ store: DeviceStore, _ plan: ShellCopyPlan) -> (result: () -> ShellCopyDecision?, done: XCTestExpectation) {
        final class Box: @unchecked Sendable { var value: ShellCopyDecision? }
        let box = Box(), done = expectation(description: "answered")
        DispatchQueue.global().async { box.value = store.askCopy(plan); done.fulfill() }
        return ({ box.value }, done)
    }

    private func waitForQuestion(_ store: DeviceStore) {
        let deadline = Date().addingTimeInterval(5)
        while store.shellCopy == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testTheCopyQuestionShowsThePlanAndBlocksUntilItIsAnswered() {
        let store = makeStore()
        let asked = ask(store, plan())
        waitForQuestion(store)
        XCTAssertEqual(store.shellCopy, plan())
        XCTAssertNil(asked.result(), "the install waits")
        store.answerCopy(.waitForCable)
        XCTAssertNil(store.shellCopy, "the card is gone")
        wait(for: [asked.done], timeout: 5)
        XCTAssertEqual(asked.result(), .waitForCable)
    }

    func testEachAnswerReachesTheInstall() {
        for decision in [ShellCopyDecision.copy, .skip, .waitForCable] {
            let store = makeStore()
            let asked = ask(store, plan())
            waitForQuestion(store)
            store.answerCopy(decision)
            wait(for: [asked.done], timeout: 5)
            XCTAssertEqual(asked.result(), decision)
        }
    }

    func testAnAnswerWithNoQuestionDoesNothing() {
        let store = makeStore()
        store.answerCopy(.copy)
        XCTAssertNil(store.shellCopy)
    }

    func testAskingAgainClearsAnEarlierCancelOfTheWait() {
        let store = makeStore()
        store.cancelWait()
        XCTAssertTrue(store.waitCancelled)
        let asked = ask(store, plan())
        waitForQuestion(store)
        XCTAssertFalse(store.waitCancelled, "the next wait starts fresh")
        store.answerCopy(.copy)
        wait(for: [asked.done], timeout: 5)
    }

    func testTheCableWaitIsToldFromABackgroundQueueAndCanBeCancelled() {
        let store = makeStore()
        let told = expectation(description: "told")
        DispatchQueue.global().async { store.setWaiting(true); told.fulfill() }
        wait(for: [told], timeout: 5)
        let deadline = Date().addingTimeInterval(5)
        while !store.shellWaiting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(store.shellWaiting)
        XCTAssertFalse(store.waitCancelled)
        store.cancelWait()
        XCTAssertTrue(store.waitCancelled, "the poll reads it between two looks")
    }

    func testWhenTheInstallEndsNoQuestionAndNoWaitStay() {
        let store = makeStore()
        let asked = ask(store, plan())
        waitForQuestion(store)
        store.setWaiting(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        store.copyEnded()
        XCTAssertNil(store.shellCopy)
        XCTAssertFalse(store.shellWaiting)
        store.answerCopy(.skip)   // let the blocked queue go (copyEnded does not answer it: the install has ended by then)
        wait(for: [asked.done], timeout: 5)
    }
}
