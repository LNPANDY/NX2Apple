import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class DeviceStoreFrameworksTests: XCTestCase {
    private var defaults: UserDefaults!
    private let runner = FakeProcessRunner()
    private let phoneA = AppleDevice(id: "DEV-A", name: "Phone A", model: "iPhone 17", os: "26.0", reachable: true, transport: "wired")
    private let phoneB = AppleDevice(id: "DEV-B", name: "Phone B", model: "iPhone 17", os: "26.0", reachable: true, transport: "localNetwork")
    private let pokopiaTID = "0400A3A01EE4C000"

    override func setUpWithError() throws {
        defaults = TestDefaults.make("nxmodel-device-fw-tests")
    }

    func testRefreshDeviceFrameworksRevalidatesGenerationAndActiveDevice() async throws {
        let gateA = DispatchSemaphore(value: 0)
        let startedA = DispatchSemaphore(value: 0)

        let store = DeviceStore(
            runner: runner,
            defaults: defaults,
            listDevices: { _ in [self.phoneA, self.phoneB] },
            readTeams: { [] },
            discoverDeviceFrameworks: { udid, name, _ in
                XCTAssertFalse(Thread.isMainThread, "devicectl probe must run off the main thread")
                if udid == "DEV-A" {
                    startedA.signal()
                    gateA.wait()
                    return DeviceFrameworkDiscoveryResult(
                        deviceUDID: udid,
                        deviceName: name,
                        bundleID: "org.nxnative.shell.TEAM1",
                        state: .ready,
                        entries: [
                            DeviceFrameworkEntry(
                                titleID: "0100000000010000",
                                frameworkName: "DmGame0100000000010000.framework",
                                bundleID: "org.nxnative.shell.TEAM1",
                                deviceUDID: udid,
                                deviceName: name
                            ),
                        ]
                    )
                }
                return DeviceFrameworkDiscoveryResult(
                    deviceUDID: udid,
                    deviceName: name,
                    bundleID: "org.nxnative.shell.TEAM1",
                    state: .ready,
                    entries: [
                        DeviceFrameworkEntry(
                            titleID: self.pokopiaTID,
                            frameworkName: "DmGame0400A3A01EE4C000.framework",
                            bundleID: "org.nxnative.shell.TEAM1",
                            deviceUDID: udid,
                            deviceName: name
                        ),
                    ]
                )
            }
        )

        await store.refresh().value
        store.installDevice = "DEV-A"
        let taskA = store.refreshDeviceFrameworks()
        _ = startedA.wait(timeout: .now() + 2)

        // Switch target device to DEV-B while DEV-A probe is still in flight.
        store.installDevice = "DEV-B"
        let taskB = store.refreshDeviceFrameworks()
        await taskB.value
        XCTAssertEqual(store.deviceFrameworksDeviceID, "DEV-B")
        XCTAssertNotNil(store.deviceFramework(for: pokopiaTID))

        // Unblock stale DEV-A task and confirm it cannot overwrite DEV-B state.
        gateA.signal()
        await taskA.value
        XCTAssertEqual(store.deviceFrameworksDeviceID, "DEV-B")
        XCTAssertNil(store.deviceFramework(for: "0100000000010000"))
        XCTAssertNotNil(store.deviceFramework(for: pokopiaTID))
    }

    func testDisconnectClearsDeviceFrameworksAndRestrictedSurfacesState() async {
        var reachable = true
        let store = DeviceStore(
            runner: runner,
            defaults: defaults,
            listDevices: { _ in reachable ? [self.phoneA] : [] },
            readTeams: { [] },
            discoverDeviceFrameworks: { udid, name, _ in
                DeviceFrameworkDiscoveryResult(
                    deviceUDID: udid,
                    deviceName: name,
                    state: .restricted("missing get-task-allow")
                )
            }
        )

        await store.refresh().value
        await store.refreshDeviceFrameworks().value
        XCTAssertEqual(store.deviceFrameworksState, .restricted("missing get-task-allow"))
        XCTAssertTrue(store.deviceFrameworks.isEmpty)

        reachable = false
        await store.refresh().value
        await store.refreshDeviceFrameworks().value
        XCTAssertEqual(store.deviceFrameworksState, .idle)
        XCTAssertEqual(store.deviceFrameworksDeviceID, "")
        XCTAssertTrue(store.deviceFrameworks.isEmpty)
    }
}
