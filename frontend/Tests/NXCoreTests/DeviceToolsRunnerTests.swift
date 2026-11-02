import XCTest
@testable import NXCore

/// The device tools over a fake `ProcessRunner`: devicectl, the keychain, Xcode's preferences and the profile reader answer from the
/// test, so nothing here reaches a device or the keychain of this Mac.
final class DeviceToolsRunnerTests: XCTestCase {
    private let fake = FakeProcessRunner()

    private func listing(_ udid: String, name: String) -> Data {
        let device: [String: Any] = [
            "hardwareProperties": ["reality": "physical", "platform": "iOS", "udid": udid, "marketingName": "iPhone 17"],
            "deviceProperties": ["name": name, "osVersionNumber": "27.0"],
            "connectionProperties": ["pairingState": "paired", "transportType": "wired"]]
        return try! JSONSerialization.data(withJSONObject: ["result": ["devices": [device]]])
    }

    func testDevicesAskDevicectlForAJsonFileAndReadIt() {
        fake.answer = { launch in
            // devicectl writes its JSON to the file the argument names
            if let i = launch.arguments.firstIndex(of: "--json-output") { try? self.listing("UDID-1", name: "Jo's iPhone").write(to: URL(fileURLWithPath: launch.arguments[i + 1])) }
            return ProcessResult()
        }
        let devices = DeviceTools.devices(xcrun: "/fake/xcrun", timeout: 20, runner: fake)
        XCTAssertEqual(devices.map(\.id), ["UDID-1"])
        XCTAssertEqual(devices.first?.name, "Jo's iPhone")
        XCTAssertEqual(devices.first?.wired, true)
        let launch = fake.launches[0]
        XCTAssertEqual(launch.executable, "/fake/xcrun")
        XCTAssertEqual(Array(launch.arguments.prefix(3)), ["devicectl", "list", "devices"])
        XCTAssertEqual(launch.timeout, 20)
        let file = launch.arguments.last ?? ""
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "the temporary file is removed")
    }

    func testAListingThatFailsOrTimesOutGivesNoDevices() {
        fake.answer = { _ in ProcessResult(status: 1) }
        XCTAssertEqual(DeviceTools.devices(runner: fake), [])
        fake.answer = { _ in ProcessResult(status: 15, timedOut: true) }
        XCTAssertEqual(DeviceTools.devices(timeout: 1, runner: fake), [])
        fake.answer = { _ in .failedToStart("no xcrun") }
        XCTAssertEqual(DeviceTools.devices(runner: fake), [])
    }

    func testCertificateTeamsReadTheKeychainAndPipeTheCertificateToOpenssl() {
        fake.answer = { launch in
            switch (launch.executable as NSString).lastPathComponent {
            case "security" where launch.arguments.first == "find-identity":
                return ProcessResult(out: "  1) AAAA \"Apple Development: Jo Doe (ABCDE12345)\"\n  2) BBBB \"Developer ID Application: X (ZZZZZZZZZZ)\"\n")
            case "security": return ProcessResult(out: "PEM")
            case "openssl": return ProcessResult(out: "subject=UID=x, OU=ABCDE12345, CN=Apple Development")
            default: return ProcessResult(status: 1)
            }
        }
        XCTAssertEqual(DeviceTools.certificateTeams(runner: fake), [SigningTeam(id: "ABCDE12345", identity: "Apple Development: Jo Doe (ABCDE12345)")])
        let openssl = fake.launches.first { $0.executable.hasSuffix("openssl") }
        XCTAssertEqual(openssl?.input, "PEM", "the certificate goes in on standard input")
    }

    func testTeamsMergeTheKeychainAndXcodeAndTolerateBothMissing() {
        fake.answer = { _ in ProcessResult(status: 1) }
        XCTAssertEqual(DeviceTools.teams(runner: fake), [])
        XCTAssertEqual(DeviceTools.xcodeTeams(runner: fake), [])
    }

    func testAppSignatureReadsTheProfileThroughSecurity() throws {
        let app = NSTemporaryDirectory() + "sig-\(UUID().uuidString).app"
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: app) }
        let profile = app + "/" + AppSignature.profileName
        FileManager.default.createFile(atPath: profile, contents: Data("cms".utf8))
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": date], format: .xml, options: 0)
        fake.answer = { _ in ProcessResult(out: String(decoding: plist, as: UTF8.self)) }
        XCTAssertEqual(AppSignature.expiration(ofApp: app, runner: fake), date)
        XCTAssertEqual(fake.commands, ["security cms -D -i \(profile)"])
        fake.answer = { _ in ProcessResult(status: 1) }
        XCTAssertNil(AppSignature.expiration(ofApp: app, runner: fake))
    }

    // MARK: DeviceControl

    func testDeviceControlGivesDevicectlItsDeadlineAndThenOneOnTheProcess() {
        fake.answer = { _ in ProcessResult(out: "listed") }
        let control = DeviceControl.xcrun("/fake/xcrun", queryTimeout: 10, copyTimeout: 180, runner: fake)
        let r = control.run(["list", "apps"])
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.output, "listed")
        XCTAssertEqual(fake.launches[0].arguments, ["devicectl", "--timeout", "10", "list", "apps"])
        XCTAssertEqual(fake.launches[0].timeout, 12, "two seconds behind devicectl's own")
        XCTAssertTrue(fake.launches[0].mergesErrors)
        _ = control.run(["device", "copy", "to", "x"])
        XCTAssertEqual(fake.launches[1].arguments.prefix(3), ["devicectl", "--timeout", "180"])
        XCTAssertEqual(fake.launches[1].timeout, 182)
    }

    func testDeviceControlSaysTimedOutWhenTheProcessWasEnded() {
        fake.answer = { _ in ProcessResult(status: 15, out: "partial", timedOut: true) }
        let r = DeviceControl.xcrun("/fake/xcrun", runner: fake).run(["list"])
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.output, DeviceControl.timedOut)
    }

    func testDeviceControlReportsAFailureAndATool​ThatDoesNotStart() {
        fake.answer = { _ in ProcessResult(status: 1, out: "ERROR: locked") }
        var r = DeviceControl.xcrun("/fake/xcrun", runner: fake).run(["list"])
        XCTAssertEqual(r.ok, false)
        XCTAssertEqual(r.output, "ERROR: locked")
        fake.answer = { _ in .failedToStart("no such file") }
        r = DeviceControl.xcrun("/fake/xcrun", runner: fake).run(["list"])
        XCTAssertEqual(r.ok, false)
        XCTAssertEqual(r.output, "no such file")
    }

    func testTheRealRunnerEndsADevicectlThatHangs() {
        // A stand-in xcrun that ignores its arguments and never returns: the process deadline ends it.
        let script = NSTemporaryDirectory() + "hang-\(UUID().uuidString).sh"
        FileManager.default.createFile(atPath: script, contents: Data("#!/bin/sh\nexec sleep 30\n".utf8), attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: script) }
        let start = Date()
        let r = DeviceControl.xcrun(script, queryTimeout: 0.2).run(["list"])
        XCTAssertEqual(r.output, DeviceControl.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }
}
