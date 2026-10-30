import XCTest
@testable import NSPortBuilder

/// Issue #250: the game's save found on the device itself, a choice between an iPhone and an iPad, and a device that does not
/// answer. devicectl is the stand-in of SaveTransferTests (a folder per device), so no test reaches a device.
final class SaveDiscoveryTests: XCTestCase {
    private typealias Fake = SaveTransferTests.FakeDevice
    private var temporary: URL!
    private let titleID = "0100535012974000"
    private let fm = FileManager.default
    private let older = Date(timeIntervalSince1970: 1_700_000_000), newer = Date(timeIntervalSince1970: 1_760_000_000)
    private let iPhone = AppleDevice(id: "PHONE", name: "Zijad's iPhone", model: "iPhone 17", os: "27.0", reachable: true)
    private let iPad = AppleDevice(id: "PAD", name: "Zijad's iPad", model: "iPad Pro", os: "27.0", reachable: true)

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("nxnative-discovery-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: temporary) }

    private func write(_ text: String, _ url: URL, date: Date) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    private func fake(_ name: String) -> Fake { Fake(temporary.appendingPathComponent(name)) }

    /// Routes a command to the device it names, as devicectl does.
    private func fleet(_ devices: [String: Fake]) -> DeviceControl {
        DeviceControl { args in
            guard let i = args.firstIndex(of: "--device"), let device = devices[args[i + 1]] else { return (false, "ERROR: no such device") }
            return device.control.run(args)
        }
    }

    private func template(_ control: DeviceControl) -> SaveTransfer {
        let mac = SaveTransfer.legacyMacSave(titleID: titleID, support: temporary.appendingPathComponent("Application Support"))
        var t = SaveTransfer(titleID: titleID, macSave: mac, device: "", bundle: "", devicectl: control)
        t.scratch = temporary
        t.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        return t
    }

    private func model(_ control: DeviceControl, devices: [AppleDevice], recorded: String = "", remembered: String = "",
                       timeout: TimeInterval = 5, name: String = "Hades", bundle: String? = nil) -> SavesModel {
        SavesModel(template: template(control), name: name, recordedBundle: bundle, recordedDevice: recorded, installTarget: "",
                   remembered: remembered, listDevices: { devices }, timeout: timeout)
    }

    private func wait(_ what: String, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), what)
    }

    // ---- the app is found on the device ----

    func testTheGameIsFoundByBundleIDPatternThenByName() {
        let apps = [InstalledApp(bundle: "com.apple.mobilesafari", name: "Safari"),
                    InstalledApp(bundle: "org.nxnative.otherthing", name: "Other"),
                    InstalledApp(bundle: "org.nxnative.\(titleID.lowercased()).ABCDE12345", name: "Hades"),
                    InstalledApp(bundle: "org.nxnative.\(titleID.lowercased())", name: "Hades"),
                    InstalledApp(bundle: "com.lcsign.x1", name: "Hades")]
        func match(_ list: [InstalledApp], name: String = "Hades", recorded: String? = nil) -> String? {
            SaveDiscovery.match(list, titleID: titleID, name: name, recordedBundle: recorded)?.bundle
        }
        XCTAssertEqual(match(apps), "org.nxnative.\(titleID.lowercased())", "the launcher's own ID first")
        XCTAssertEqual(match(apps, recorded: "com.lcsign.x1"), "com.lcsign.x1", "the one this launcher recorded beats the pattern")
        XCTAssertEqual(match(Array(apps.dropLast(2))), "org.nxnative.\(titleID.lowercased()).ABCDE12345", "a team suffix")
        XCTAssertEqual(match([apps[0], InstalledApp(bundle: "dev.resigner.\(titleID.uppercased())", name: "x")]), "dev.resigner.\(titleID.uppercased())", "the title ID inside any ID, any case")
        XCTAssertEqual(match([apps[0], apps[4]]), "com.lcsign.x1", "a re-signed app under another ID, by its name")
        XCTAssertEqual(match([apps[0], InstalledApp(bundle: "a.b", name: "  hades ")]), "a.b", "the name, trimmed and case-blind")
        XCTAssertNil(match([apps[0], apps[1]]))
        XCTAssertNil(match([apps[0], apps[1], apps[4]], name: ""), "no name to match and no title ID in any ID")
        XCTAssertEqual(SaveDiscovery.match([InstalledApp(bundle: "b.two", name: "Hades"), InstalledApp(bundle: "a.one", name: "Hades")],
                                           titleID: titleID, name: "Hades", recordedBundle: nil)?.bundle, "a.one", "equal matches: the same answer every time")
    }

    func testTheAppsListingIsParsed() throws {
        let json = #"{"result": {"apps": [{"bundleIdentifier": "a.b", "name": "A"}, {"name": "no id"}, {"bundleIdentifier": "c.d"}]}}"#
        XCTAssertEqual(SaveDiscovery.parseApps(Data(json.utf8)), [InstalledApp(bundle: "a.b", name: "A"), InstalledApp(bundle: "c.d", name: "")])
        XCTAssertNil(SaveDiscovery.parseApps(Data("[]".utf8)))
        let command = SaveDiscovery.listCommand(device: "PHONE", json: "/tmp/x.json")
        XCTAssertTrue(command.contains("--include-default-apps"), "a game signed by another tool is not a developer app")
    }

    /// A game installed another way (the exported IPA, re-signed): no install record, no cached signed app, another bundle ID.
    func testAGameInstalledAnotherWayIsFoundAndItsSaveCopied() throws {
        let phone = fake("phone")
        phone.apps = [("com.apple.mobilesafari", "Safari"), ("com.lcsign.hades42", "Hades")]
        try write("legacy", phone.container.appendingPathComponent("Documents/save/SYSTEM.DAT"), date: newer)
        let m = model(fleet(["PHONE": phone]), devices: [iPhone])
        m.begin()
        wait("ready") { m.deviceSave != nil }
        XCTAssertEqual(m.deviceSave, SaveTransfer.Contents(folders: ["save"], newest: newer))
        let found = try XCTUnwrap(m.found)
        XCTAssertEqual(found.bundle, "com.lcsign.hades42")
        _ = try found.deviceToMac()
        XCTAssertEqual(read(found.macSave.appendingPathComponent("SYSTEM.DAT")), "legacy")
        try write("edited", found.macSave.appendingPathComponent("SYSTEM.DAT"), date: newer)
        _ = try found.macToDevice()
        XCTAssertEqual(read(phone.container.appendingPathComponent("Documents/save/SYSTEM.DAT")), "edited", "back where the app keeps it")
        XCTAssertFalse(fm.fileExists(atPath: phone.container.appendingPathComponent("Documents/games").path))
        for call in phone.calls where call.prefix(3) != ["device", "info", "apps"] {
            XCTAssertEqual(phone.value("--domain-identifier", call), "com.lcsign.hades42")
        }
    }

    func testAGameThatIsNotOnTheDeviceIsSaidSo() {
        let phone = fake("phone")
        phone.apps = [("com.apple.mobilesafari", "Safari")]
        let m = model(fleet(["PHONE": phone]), devices: [iPhone])
        m.begin()
        wait("answered") { !m.isReading }
        XCTAssertEqual(m.deviceState, .notInstalled)
        XCTAssertNil(m.found)
    }

    // ---- both save layouts ----

    private func transfer(_ device: Fake, bundle: String = "com.example.game") -> SaveTransfer {
        var t = template(device.control)
        t = SaveTransfer(titleID: titleID, macSave: t.macSave, device: "PHONE", bundle: bundle, devicectl: device.control)
        t.scratch = temporary
        t.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        return t
    }

    func testDocumentsSaveAndThePerGameSaveAreBothRead() throws {
        let plain = fake("plain"), perGame = fake("pergame"), both = fake("both"), none = fake("none")
        try write("a", plain.container.appendingPathComponent("Documents/save/data.bin"), date: older)
        try write("b", perGame.container.appendingPathComponent("Documents/games/\(titleID)/save/data.bin"), date: newer)
        try write("img", perGame.container.appendingPathComponent("Documents/games/\(titleID)/romfs.img"), date: older)
        try write("a", both.container.appendingPathComponent("Documents/save/data.bin"), date: older)
        try write("b", both.container.appendingPathComponent("Documents/games/\(titleID)/save/data.bin"), date: newer)
        try write("img", both.container.appendingPathComponent("Documents/games/\(titleID)/romfs.img"), date: older)
        try write("img", none.container.appendingPathComponent("Documents/games/\(titleID)/romfs.img"), date: older)
        try fm.createDirectory(at: plain.container.appendingPathComponent("Documents/games"), withIntermediateDirectories: true)
        let t = transfer(plain)
        XCTAssertEqual(try t.resolveDevice().base, "Documents")
        XCTAssertEqual(try t.resolveDevice().contents, SaveTransfer.Contents(folders: ["save"], newest: older))
        XCTAssertEqual(try transfer(perGame).resolveDevice().base, "Documents/games/\(titleID)")
        XCTAssertEqual(try transfer(perGame).resolveDevice().contents.newest, newer)
        XCTAssertEqual(try transfer(both).resolveDevice().base, "Documents/games/\(titleID)", "both: the one the game's files are in")
        XCTAssertEqual(try transfer(none).resolveDevice().base, "Documents/games/\(titleID)", "no save yet: where the game's files are")
        XCTAssertEqual(try transfer(none).readDevice(), SaveTransfer.Contents())
    }

    func testACopyToTheDeviceGoesToTheLayoutInUse() throws {
        let plain = fake("plain")
        try write("old", plain.container.appendingPathComponent("Documents/save/data.bin"), date: older)
        let t = transfer(plain)
        try write("mac", t.macSave.appendingPathComponent("data.bin"), date: newer)
        let backup = try XCTUnwrap(try t.macToDevice())
        XCTAssertEqual(read(backup.appendingPathComponent("save/data.bin")), "old", "the confirmation's backup is made in both layouts")
        XCTAssertEqual(read(plain.container.appendingPathComponent("Documents/save/data.bin")), "mac")
        let copyTo = try XCTUnwrap(plain.calls.first { $0.prefix(3) == ["device", "copy", "to"] })
        XCTAssertEqual(plain.value("--destination", copyTo), "Documents/save")
        // A device with no save and no game files in a per-game folder: the save goes into Documents too
        let fresh = fake("fresh")
        try fm.createDirectory(at: fresh.container.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        XCTAssertNil(try transfer(fresh).macToDevice())
        XCTAssertEqual(read(fresh.container.appendingPathComponent("Documents/save/data.bin")), "mac")
    }

    // ---- two devices ----

    func testTheSelectorStartsOnTheRecordedDeviceAndAsksTheOneChosen() throws {
        let phone = fake("phone"), pad = fake("pad")
        phone.apps = [("org.nxnative.\(titleID.lowercased())", "Hades")]
        pad.apps = [("com.lcsign.hades", "Hades")]
        try write("p", phone.container.appendingPathComponent("Documents/games/\(titleID)/save/data.bin"), date: older)
        try write("d", pad.container.appendingPathComponent("Documents/save/data.bin"), date: newer)
        let control = fleet(["PHONE": phone, "PAD": pad])
        var remembered: [String] = []
        let m = SavesModel(template: template(control), name: "Hades", recordedBundle: nil, recordedDevice: "PAD", installTarget: "PHONE",
                           rememberChoice: { remembered.append($0) }, listDevices: { [self.iPhone, self.iPad] }, timeout: 5)
        XCTAssertFalse(m.showsSelector, "nothing listed yet")
        m.begin()
        wait("ready") { m.deviceSave != nil }
        XCTAssertTrue(m.showsSelector)
        XCTAssertEqual(m.selected, "PAD", "the device the game was installed on")
        XCTAssertEqual(m.selectedDevice?.name, "Zijad's iPad")
        XCTAssertEqual(m.found?.device, "PAD")
        XCTAssertEqual(m.deviceSave?.newest, newer)
        XCTAssertTrue(phone.calls.isEmpty, "the other device is not asked")
        m.select("PHONE")
        XCTAssertEqual(m.deviceState, .reading)
        XCTAssertEqual(m.selected, "PHONE")
        wait("the iPhone answered") { m.found?.device == "PHONE" && m.deviceSave != nil }
        XCTAssertEqual(m.deviceSave?.newest, older)
        XCTAssertEqual(m.found?.bundle, "org.nxnative.\(titleID.lowercased())")
        XCTAssertEqual(remembered, ["PHONE"])
        m.refresh()
        wait("refreshed") { m.deviceSave != nil }
        XCTAssertEqual(m.selected, "PHONE", "a refresh keeps the choice")
    }

    func testTheDefaultDeviceFollowsWhatIsConnected() {
        let away = AppleDevice(id: "AWAY", name: "Away", model: "iPhone", os: "27.0", reachable: false)
        func pick(_ list: [AppleDevice], remembered: String = "", recorded: String = "", target: String = "") -> String? {
            SavesModel.defaultDevice(in: list, remembered: remembered, recorded: recorded, installTarget: target)
        }
        XCTAssertEqual(pick([iPhone, iPad], remembered: "PAD", recorded: "PHONE"), "PAD", "the choice made here first")
        XCTAssertEqual(pick([away, iPad], recorded: "AWAY"), "PAD", "a device that is not connected is passed over")
        XCTAssertEqual(pick([away], recorded: "AWAY"), "AWAY", "when nothing is connected, its name is shown with the reason")
        XCTAssertEqual(pick([iPhone, iPad], target: "PAD"), "PAD")
        XCTAssertEqual(pick([iPad, iPhone], recorded: "GONE"), "PAD")
        XCTAssertNil(pick([]))
    }

    func testADeviceThatIsNotConnectedIsNotAsked() {
        let away = AppleDevice(id: "AWAY", name: "Away", model: "iPad", os: "27.0", reachable: false)
        let phone = fake("away")
        let m = model(fleet(["AWAY": phone]), devices: [away], recorded: "AWAY")
        m.begin()
        wait("answered") { !m.isReading }
        XCTAssertEqual(m.deviceState, .notConnected)
        XCTAssertTrue(phone.calls.isEmpty, "a connection that is not ready is what hangs")
        let none = model(fleet([:]), devices: [])
        none.begin()
        wait("answered") { !none.isReading }
        XCTAssertEqual(none.deviceState, .noDevices)
    }

    // ---- a device that does not answer ----

    func testAQueryThatNeverAnswersEndsAtTheTimeoutAndItsLateAnswerIsDropped() throws {
        let phone = fake("phone")
        phone.apps = [("com.lcsign.hades", "Hades")]
        try write("late", phone.container.appendingPathComponent("Documents/save/data.bin"), date: newer)
        let gate = DispatchSemaphore(value: 0)
        phone.hang = gate
        let m = model(fleet(["PHONE": phone]), devices: [iPhone], timeout: 0.3)
        m.begin()
        XCTAssertEqual(m.deviceState, .reading)
        XCTAssertFalse(m.canRefresh)
        wait("timed out") { m.deviceState == .timedOut }
        XCTAssertTrue(m.canRefresh, "Refresh is back")
        phone.hang = nil
        gate.signal()   // the stuck command finally answers, after the sheet gave up on it
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(m.deviceState, .timedOut, "a stale answer does not overwrite the message")
        XCTAssertNil(m.found)
        m.refresh()   // and a new try works
        wait("ready") { m.deviceSave != nil }
    }

    func testACommandThatTimedOutIsATimeoutNotAnEmptySave() throws {
        let timedOut = DeviceControl { _ in (false, DeviceControl.timedOut) }
        let t = SaveTransfer(titleID: titleID, macSave: temporary.appendingPathComponent("save"), device: "PHONE", bundle: "x", devicectl: timedOut)
        XCTAssertThrowsError(try t.readDevice()) { XCTAssertEqual($0 as? SaveTransfer.Failure, .timeout) }
        // devicectl's own deadline says "timed out" in its words
        XCTAssertEqual(SaveTransfer.failure("ERROR: The operation timed out. (CoreDeviceError 9)"), .timeout)
        XCTAssertEqual(SaveTransfer.failure("Acquired tunnel\nERROR: not connected"), .device("ERROR: not connected"))
        // a save folder that times out in the middle is no "no save yet"
        let phone = fake("phone")
        try write("a", phone.container.appendingPathComponent("Documents/save/data.bin"), date: older)
        let inner = phone.control
        let flaky = DeviceControl { args in
            args.contains("Documents/save") ? (false, DeviceControl.timedOut) : inner.run(args)
        }
        let u = SaveTransfer(titleID: titleID, macSave: temporary.appendingPathComponent("save"), device: "PHONE", bundle: "x", devicectl: flaky)
        XCTAssertThrowsError(try u.readDevice()) { XCTAssertEqual($0 as? SaveTransfer.Failure, .timeout) }
    }

    func testARealCommandThatHangsIsStopped() throws {
        let command = temporary.appendingPathComponent("unresponsive-xcrun")   // stands in for xcrun, never devicectl
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: command, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let started = Date()
        let result = DeviceControl.xcrun(command.path, queryTimeout: 0.2).run(["device", "info", "files"])
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.output, DeviceControl.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // ---- refresh while a query runs ----

    func testRefreshWhileAQueryRunsDoesNothingAndAnotherDeviceReplacesIt() throws {
        let phone = fake("phone"), pad = fake("pad")
        phone.apps = [("com.lcsign.hades", "Hades")]
        pad.apps = [("com.lcsign.hades", "Hades")]
        try write("p", phone.container.appendingPathComponent("Documents/save/data.bin"), date: older)
        try write("d", pad.container.appendingPathComponent("Documents/save/data.bin"), date: newer)
        let gate = DispatchSemaphore(value: 0)
        phone.hang = gate
        let m = model(fleet(["PHONE": phone, "PAD": pad]), devices: [iPhone, iPad], remembered: "PHONE")
        m.begin()
        wait("the iPhone is asked") { !phone.calls.isEmpty && m.showsSelector }
        m.refresh(); m.refresh(); m.begin()
        XCTAssertEqual(m.deviceState, .reading)
        m.select("PAD")   // the iPad is asked in its place
        wait("the iPad answered") { m.deviceSave != nil }
        XCTAssertEqual(m.found?.device, "PAD")
        XCTAssertEqual(m.deviceSave?.newest, newer)
        phone.hang = nil
        gate.signal()     // the iPhone's answer comes after, and is dropped
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(m.found?.device, "PAD")
        XCTAssertEqual(m.deviceSave?.newest, newer)
        XCTAssertEqual(phone.calls.filter { $0.prefix(3) == ["device", "info", "apps"] }.count, 1, "the clicks while it ran asked nothing")
    }
}
