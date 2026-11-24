import XCTest
@testable import NXCore

final class DeviceFrameworkSyncTests: XCTestCase {
    private let pokopiaTID = "0400A3A01EE4C000"
    private let stagedTID = "0100CD801CE5E000"
    private let incompleteStagingTID = "0100E65002BB8000"

    /// Fixture captured from real `xcrun devicectl device info files --device <UDID> --domain-type appDataContainer --domain-identifier org.nxnative.shell.<TEAM> --subdirectory Documents/Frameworks --json-output <path>`
    /// (device identifiers sanitized for repository cleanliness).
    private func realDevicectlFrameworksJSON() -> Data {
        let json = #"""
        {
          "info": {
            "arguments": [
              "devicectl", "device", "info", "files",
              "--device", "00008150-0000000000000000",
              "--domain-type", "appDataContainer",
              "--domain-identifier", "org.nxnative.shell.TESTTEAM01",
              "--subdirectory", "Documents/Frameworks",
              "--json-output", "/tmp/frameworks.json"
            ],
            "outcome": "success"
          },
          "result": {
            "deviceIdentifier": "00008150-0000000000000000",
            "domain": "appDataContainer",
            "domainIdentifier": "org.nxnative.shell.TESTTEAM01",
            "files": [
              {
                "metadata": { "lastModDate": "2026-11-22T13:52:51.000Z", "size": 234 },
                "name": ".DmGame0400A3A01EE4C000.framework.nx-local-sign.json",
                "relativePath": ".DmGame0400A3A01EE4C000.framework.nx-local-sign.json",
                "resources": { "isDirectory": false, "isHidden": true, "isReadable": true, "isSymbolicLink": false, "isWritable": true }
              },
              {
                "metadata": { "lastModDate": "2026-11-24T05:13:50.000Z", "size": 128 },
                "name": ".staging-0100CD801CE5E000-1e64aa6c",
                "relativePath": ".staging-0100CD801CE5E000-1e64aa6c",
                "resources": { "isDirectory": true, "isHidden": true, "isReadable": true, "isSymbolicLink": false, "isWritable": true }
              },
              {
                "metadata": { "lastModDate": "2026-11-24T05:13:48.000Z", "size": 69 },
                "name": ".staging-0100CD801CE5E000-1e64aa6c/.ready",
                "relativePath": ".staging-0100CD801CE5E000-1e64aa6c/.ready",
                "resources": { "isDirectory": false, "isHidden": true, "isReadable": true, "isSymbolicLink": false, "isWritable": true }
              },
              {
                "metadata": { "lastModDate": "2026-11-24T05:13:48.000Z", "size": 416 },
                "name": ".staging-0100CD801CE5E000-1e64aa6c/DmGame0100CD801CE5E000.framework",
                "relativePath": ".staging-0100CD801CE5E000-1e64aa6c/DmGame0100CD801CE5E000.framework",
                "resources": { "isDirectory": true, "isHidden": false, "isReadable": true, "isSymbolicLink": false, "isWritable": true }
              },
              {
                "metadata": { "lastModDate": "2026-11-24T05:13:00.000Z", "size": 24700000 },
                "name": ".staging-0100CD801CE5E000-1e64aa6c/DmGame0100CD801CE5E000.framework/DmGame0100CD801CE5E000",
                "relativePath": ".staging-0100CD801CE5E000-1e64aa6c/DmGame0100CD801CE5E000.framework/DmGame0100CD801CE5E000",
                "resources": { "isDirectory": false, "isHidden": false, "isReadable": true, "isSymbolicLink": false, "isWritable": true }
              },
              {
                "metadata": { "lastModDate": "2026-11-24T05:09:00.000Z", "size": 765 },
                "name": ".staging-0100CD801CE5E000-1e64aa6c/DmGame0100CD801CE5E000.framework/game.manifest.json",
                "relativePath": ".staging-0100CD801CE5E000-1e64aa6c/DmGame0100CD801CE5E000.framework/game.manifest.json",
                "resources": { "isDirectory": false, "isHidden": false, "isReadable": true, "isSymbolicLink": false, "isWritable": true }
              },
              {
                "metadata": { "lastModDate": "2026-11-24T05:14:00.000Z", "size": 128 },
                "name": ".staging-0100E65002BB8000-d6c34e8d",
                "relativePath": ".staging-0100E65002BB8000-d6c34e8d",
                "resources": { "isDirectory": true, "isHidden": true, "isReadable": true, "isSymbolicLink": false, "isWritable": true }
              },
              {
                "metadata": { "lastModDate": "2026-11-24T05:13:50.000Z", "size": 1024 },
                "name": ".staging-0100E65002BB8000-d6c34e8d/DmGame0100E65002BB8000.framework/DmGame0100E65002BB8000",
                "relativePath": ".staging-0100E65002BB8000-d6c34e8d/DmGame0100E65002BB8000.framework/DmGame0100E65002BB8000",
                "resources": { "isDirectory": false, "isHidden": false, "isReadable": true, "isSymbolicLink": false, "isWritable": true }
              },
              {
                "metadata": { "lastModDate": "2026-11-22T13:52:00.000Z", "size": 384 },
                "name": "DmGame0400A3A01EE4C000.framework",
                "relativePath": "DmGame0400A3A01EE4C000.framework",
                "resources": { "isDirectory": true, "isHidden": false, "isReadable": true, "isSymbolicLink": false, "isWritable": true }
              },
              {
                "metadata": { "lastModDate": "2026-11-22T13:52:00.000Z", "size": 87700000 },
                "name": "DmGame0400A3A01EE4C000.framework/DmGame0400A3A01EE4C000",
                "relativePath": "DmGame0400A3A01EE4C000.framework/DmGame0400A3A01EE4C000",
                "resources": { "isDirectory": false, "isHidden": false, "isReadable": true, "isSymbolicLink": false, "isWritable": true }
              },
              {
                "metadata": { "lastModDate": "2026-11-22T13:46:39.000Z", "size": 799 },
                "name": "DmGame0400A3A01EE4C000.framework/game.manifest.json",
                "relativePath": "DmGame0400A3A01EE4C000.framework/game.manifest.json",
                "resources": { "isDirectory": false, "isHidden": false, "isReadable": true, "isSymbolicLink": false, "isWritable": true }
              }
            ]
          }
        }
        """#
        return Data(json.utf8)
    }

    func testParseRealDevicectlFrameworksListingPromotedAndReadyStagedOnly() {
        let entries = DeviceFrameworkSync.parseFrameworksListing(
            realDevicectlFrameworksJSON(),
            deviceUDID: "DEV-1",
            deviceName: "Test iPhone",
            bundleID: "org.nxnative.shell.TESTTEAM01"
        )
        XCTAssertNotNil(entries)
        let byID = Dictionary(uniqueKeysWithValues: (entries ?? []).map { ($0.titleID, $0) })
        XCTAssertEqual(Set(byID.keys), [stagedTID, pokopiaTID], "incomplete staging without .ready must be ignored")

        let pokopia = byID[pokopiaTID]!
        XCTAssertEqual(pokopia.frameworkName, "DmGame0400A3A01EE4C000.framework")
        XCTAssertEqual(pokopia.bundleID, "org.nxnative.shell.TESTTEAM01")
        XCTAssertNil(byID[incompleteStagingTID])
    }

    func testParseListingEnforcesStrict16HexTitleIDAndRejectsSymlinksAndTraversal() throws {
        XCTAssertNil(DeviceFrameworkSync.parseFrameworksListing(Data("not json".utf8), deviceUDID: "D", deviceName: "N", bundleID: "B"))
        XCTAssertTrue(DeviceFrameworkSync.isValidTitleID("0400A3A01EE4C000"))
        XCTAssertFalse(DeviceFrameworkSync.isValidTitleID("0400A3A01EE4C00"))
        XCTAssertFalse(DeviceFrameworkSync.isValidTitleID("0400A3A01EE4C00G"))

        let payload: [String: Any] = [
            "result": [
                "files": [
                    [
                        "relativePath": "DmGame0400A3A01EE4C000.framework",
                        "resources": ["isDirectory": true, "isSymbolicLink": true],
                    ],
                    [
                        "relativePath": "DmGame0100000000010000.framework",
                        "resources": ["isDirectory": true, "isSymbolicLink": false],
                    ],
                    [
                        "relativePath": "DmGame0100000000010000.framework/../escape",
                        "resources": ["isDirectory": false, "isSymbolicLink": false],
                    ],
                    [
                        "relativePath": "DmGameZZZZ000000000000.framework",
                        "resources": ["isDirectory": true, "isSymbolicLink": false],
                    ],
                    [
                        "relativePath": "DmGame0100ABCD.framework",
                        "resources": ["isDirectory": true, "isSymbolicLink": false],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let entries = DeviceFrameworkSync.parseFrameworksListing(data, deviceUDID: "D", deviceName: "N", bundleID: "B")
        XCTAssertEqual(entries, [])
    }

    func testDiscoverFrameworksHandlesReadyAndRestrictedGracefully() throws {
        let appsJSON = #"""
        {
          "result": {
            "apps": [
              { "bundleIdentifier": "org.nxnative.shell.TESTTEAM01", "name": "NX2Apple", "url": "file:///App.app" }
            ]
          }
        }
        """#
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            let args = launch.arguments
            if let idx = args.firstIndex(of: "--json-output"), idx + 1 < args.count {
                let path = args[idx + 1]
                if args.contains("apps") {
                    try? Data(appsJSON.utf8).write(to: URL(fileURLWithPath: path))
                    return ProcessResult(status: 0)
                }
                if args.contains("files") {
                    try? self.realDevicectlFrameworksJSON().write(to: URL(fileURLWithPath: path))
                    return ProcessResult(status: 0)
                }
            }
            return ProcessResult(status: 1, out: "unexpected")
        }

        let control = DeviceControl.xcrun("/usr/bin/xcrun", runner: runner)
        let ready = DeviceFrameworkSync.discoverFrameworks(
            deviceUDID: "DEV-1",
            deviceName: "Test iPhone",
            control: control
        )
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(Set(ready.entries.map(\.titleID)), [stagedTID, pokopiaTID])

        // Distribution .p12 signed shell without get-task-allow degrades to .restricted without crashing.
        runner.answer = { launch in
            let args = launch.arguments
            if args.contains("apps"), let idx = args.firstIndex(of: "--json-output"), idx + 1 < args.count {
                try? Data(appsJSON.utf8).write(to: URL(fileURLWithPath: args[idx + 1]))
                return ProcessResult(status: 0)
            }
            return ProcessResult(status: 1, out: "Application is not debuggable (missing com.apple.security.get-task-allow entitlement)")
        }
        let restricted = DeviceFrameworkSync.discoverFrameworks(
            deviceUDID: "DEV-1",
            deviceName: "Test iPhone",
            control: control
        )
        if case .restricted = restricted.state {
            XCTAssertTrue(restricted.entries.isEmpty)
        } else {
            XCTFail("Expected .restricted, got \(restricted.state)")
        }
    }
}
