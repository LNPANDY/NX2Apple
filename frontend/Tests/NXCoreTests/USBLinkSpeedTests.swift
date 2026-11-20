import XCTest
@testable import NXCore

final class USBLinkSpeedTests: XCTestCase {
    func testNormalizeAndMatchUDIDCaseInsensitivelyWithoutHyphens() {
        XCTAssertEqual(USBLinkSpeed.normalizeUDID("00008150-000660C01447801C"), "00008150000660C01447801C")
        XCTAssertTrue(USBLinkSpeed.matchesUDID(
            "00008150-000660C01447801C",
            properties: ["kUSBSerialNumberString": "00008150000660c01447801c"]
        ))
        XCTAssertTrue(USBLinkSpeed.matchesUDID(
            "00008150-000660C01447801C",
            properties: ["USB Serial Number": "00008150-000660C01447801C"]
        ))
        XCTAssertFalse(USBLinkSpeed.matchesUDID(
            "00008150-000660C01447801C",
            properties: ["kUSBSerialNumberString": "00008150000660C01447801D"]
        ))
    }

    func testExtractSpeedBpsPrefersUsbLinkSpeedAndFallsBackToUSBSpeedCodes() {
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["UsbLinkSpeed": NSNumber(value: 10_000_000_000 as Int64)]), 10_000_000_000)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["UsbLinkSpeed": NSNumber(value: 480_000_000 as Int64)]), 480_000_000)
        // USBSpeed (tIOUSBHostConnectionSpeed, 1-based): 3 = High (480 Mbps), 4 = Super (5 Gbps), 5 = Super+ (10 Gbps)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["USBSpeed": 1]), 12_000_000)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["USBSpeed": 2]), 1_500_000)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["USBSpeed": 3]), 480_000_000)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["USBSpeed": 4]), 5_000_000_000)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["USBSpeed": 5]), 10_000_000_000)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["USBSpeed": 6]), 20_000_000_000)
        // Device Speed (kUSBDeviceSpeed*, 0-based): 2 = High (480 Mbps), 3 = Super (5 Gbps), 4 = Super+ (10 Gbps)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["Device Speed": 0]), 1_500_000)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["Device Speed": 1]), 12_000_000)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["Device Speed": 2]), 480_000_000)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["Device Speed": 3]), 5_000_000_000)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["Device Speed": 4]), 10_000_000_000)
        XCTAssertEqual(USBLinkSpeed.extractSpeedBps(from: ["Device Speed": 5]), 20_000_000_000)
        XCTAssertNil(USBLinkSpeed.extractSpeedBps(from: [:]))
    }

    func testProfileClassificationRateFormattingAndDurationEstimates() {
        let high = USBLinkSpeed.profile(connection: .wired, usbSpeedBps: 10_000_000_000)
        XCTAssertEqual(high, .highSpeedUSB(bps: 10_000_000_000))
        XCTAssertEqual(high.rateText, "10 Gbps")
        XCTAssertTrue(high.isHighSpeedUSB)
        XCTAssertFalse(high.isUSB2)

        let fiveG = USBLinkSpeed.profile(connection: .wired, usbSpeedBps: 5_000_000_000)
        XCTAssertEqual(fiveG, .highSpeedUSB(bps: 5_000_000_000))
        XCTAssertEqual(fiveG.rateText, "5 Gbps")

        let usb2 = USBLinkSpeed.profile(connection: .wired, usbSpeedBps: 480_000_000)
        XCTAssertEqual(usb2, .usb2(bps: 480_000_000))
        XCTAssertEqual(usb2.rateText, "480 Mbps")
        XCTAssertTrue(usb2.isUSB2)

        let wifi = USBLinkSpeed.profile(connection: .network, usbSpeedBps: nil)
        XCTAssertEqual(wifi, .wifi)
        XCTAssertEqual(USBLinkSpeed.profile(connection: .wired, usbSpeedBps: nil), .wiredUnknown)
        XCTAssertEqual(USBLinkSpeed.profile(connection: .notConnected, usbSpeedBps: 10_000_000_000), .disconnected)

        // 15 GB throughput estimates: highSpeed ~110-130 MB/s (2 min), usb2 ~28-35 MB/s (7-9 min), wifi ~17-25 MB/s (10-15 min)
        let bytes: Int64 = 15_000_000_000
        let estHigh = USBLinkSpeed.estimateMinutes(bytes: bytes, profile: high)
        XCTAssertEqual(estHigh?.low, 2)
        XCTAssertEqual(estHigh?.high, 2)

        let estUSB2 = USBLinkSpeed.estimateMinutes(bytes: bytes, profile: usb2)
        XCTAssertEqual(estUSB2?.low, 7)
        XCTAssertEqual(estUSB2?.high, 9)

        let estWifi = USBLinkSpeed.estimateMinutes(bytes: bytes, profile: wifi)
        XCTAssertEqual(estWifi?.low, 10)
        XCTAssertEqual(estWifi?.high, 15)

        XCTAssertNil(USBLinkSpeed.estimateMinutes(bytes: bytes, profile: .wiredUnknown))
        XCTAssertNil(USBLinkSpeed.estimateMinutes(bytes: bytes, profile: .disconnected))
    }

    func testPostBuildTransferModeDefaultsToAsk() {
        XCTAssertEqual(PostBuildTransferMode.defaultMode, .ask)
        XCTAssertEqual(PostBuildTransferMode.fromStored(nil), .ask)
        XCTAssertEqual(PostBuildTransferMode.fromStored(""), .ask)
        XCTAssertEqual(PostBuildTransferMode.fromStored("bogus"), .ask)
        XCTAssertEqual(PostBuildTransferMode.fromStored("auto"), .auto)
        XCTAssertEqual(PostBuildTransferMode.fromStored("skip"), .skip)
        XCTAssertEqual(PostBuildTransferMode.fromStored("ask"), .ask)
    }

    func testCopyPlanReflectsHighSpeedUSB2AndWifiRecommendations() {
        var installer = ShellInstaller(repo: "/tmp/repo", python: "/usr/bin/python3", root: "/tmp/shell", device: "UDID-1", team: "TEAM123456")
        installer.deviceName = "Andy's iPhone"
        installer.lang = .en

        installer.usbSpeedLookup = { _ in 10_000_000_000 }
        let highPlan = installer.copyPlan(files: 2, bytes: 15_000_000_000, connection: .wired)
        XCTAssertEqual(highPlan.linkProfile, .highSpeedUSB(bps: 10_000_000_000))
        XCTAssertFalse(highPlan.canWaitForCable)
        XCTAssertFalse(highPlan.waitsForHighSpeedCable)
        XCTAssertTrue(highPlan.connectionText.contains("10 Gbps"))
        XCTAssertTrue(highPlan.connectionText.contains("recommended"))

        installer.usbSpeedLookup = { _ in 480_000_000 }
        let usb2Plan = installer.copyPlan(files: 2, bytes: 15_000_000_000, connection: .wired)
        XCTAssertEqual(usb2Plan.linkProfile, .usb2(bps: 480_000_000))
        XCTAssertTrue(usb2Plan.canWaitForCable)
        XCTAssertTrue(usb2Plan.waitsForHighSpeedCable)
        XCTAssertTrue(usb2Plan.connectionText.contains("480 Mbps"))
        XCTAssertTrue(usb2Plan.connectionText.contains("Wi-Fi"))

        let wifiPlan = installer.copyPlan(files: 2, bytes: 15_000_000_000, connection: .network)
        XCTAssertEqual(wifiPlan.linkProfile, .wifi)
        XCTAssertTrue(wifiPlan.canWaitForCable)
        XCTAssertFalse(wifiPlan.waitsForHighSpeedCable)
        XCTAssertTrue(wifiPlan.connectionText.contains("Wi-Fi"))
    }

    func testWaitForCableFromUSB2WaitsUntilHighSpeedUSBAppears() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usb-wait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wiredJSON = """
        {"result":{"devices":[{"hardwareProperties":{"reality":"physical","platform":"iOS","udid":"UDID-1","marketingName":"iPhone 17 Pro Max"},"deviceProperties":{"name":"Andy's iPhone","osVersionNumber":"27.0"},"connectionProperties":{"pairingState":"paired","transportType":"wired"}}]}}
        """
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            if let idx = launch.arguments.firstIndex(of: "--json-output"), idx + 1 < launch.arguments.count {
                try? Data(wiredJSON.utf8).write(to: URL(fileURLWithPath: launch.arguments[idx + 1]))
            }
            return ProcessResult(status: 0, out: "")
        }

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            var polls = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; polls += 1; return polls }
        }
        let counter = Counter()

        var installer = ShellInstaller(repo: dir.path, python: "/usr/bin/python3", root: dir.path, device: "UDID-1", team: "TEAM123456")
        installer.runner = runner
        installer.pollInterval = 0.005
        installer.usbSpeedLookup = { _ in
            counter.next() < 2 ? 480_000_000 : 10_000_000_000
        }

        let decision = installer.waitForCable(initialProfile: .usb2(bps: 480_000_000))
        XCTAssertEqual(decision, .copy)
        XCTAssertEqual(counter.polls, 2, "must not return immediately while still connected at USB 2.0")
    }

    func testWaitForCableCancelsPromptlyDespiteLongPollInterval() {
        let cancelFlag = LockedFlag()
        var installer = ShellInstaller(repo: "/tmp/repo", python: "/usr/bin/python3", root: "/tmp/shell", device: "UDID-1", team: "TEAM123456")
        installer.pollInterval = 4.0
        installer.waitCancelled = { cancelFlag.value }

        let start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            cancelFlag.set(true)
        }
        let decision = installer.waitForCable(initialProfile: .wifi)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(decision, .skip)
        XCTAssertLessThan(elapsed, 1.0, "waitForCable must respond to cancellation promptly instead of blocking for full 4s pollInterval")
    }
}
