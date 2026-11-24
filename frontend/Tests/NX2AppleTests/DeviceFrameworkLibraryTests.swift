import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

@MainActor final class DeviceFrameworkLibraryTests: IsolatedDefaultsTestCase {
    private let pokopiaTID = "0400A3A01EE4C000"
    private let otherTID = "0100000000010000"

    private func makeMacApp(in root: URL, titleID: String) throws -> URL {
        let app = root.appendingPathComponent("Pokopia.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        for exe in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(
                at: macOS.appendingPathComponent(exe),
                withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
            )
        }
        let info = ["DMTitleID": titleID, "CFBundleExecutable": "nxnative"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func testConnectedDeviceFrameworkUpdatesLibraryStateFilterWithoutMutatingPersistedLibrary() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dfw-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let libFile = tmp.appendingPathComponent("library.json")
        let macApp = try makeMacApp(in: tmp, titleID: pokopiaTID)

        let library = GameLibrary(file: libFile, artwork: tmp.appendingPathComponent("art"))
        var pokopia = LibraryGame(titleID: pokopiaTID, name: "Pokemon Pokopia")
        pokopia.appPath = macApp.path
        let other = LibraryGame(titleID: otherTID, name: "Other Game")
        library.games = [pokopia, other]
        library.save()

        // Before device connection: only Mac is known.
        let beforeState = library.artworkState(for: pokopia)
        XCTAssertTrue(beforeState.mac)
        XCTAssertFalse(beforeState.ios)
        XCTAssertNil(beforeState.chipKey)
        XCTAssertFalse(LibraryFilter.ios.includes(pokopia, state: beforeState))
        XCTAssertFalse(BuildInventoryEntry(pokopia).installed)

        // Connected iPhone reports DmGame0400A3A01EE4C000.framework in Documents/Frameworks.
        let devEntry = DeviceFrameworkEntry(
            titleID: pokopiaTID,
            frameworkName: "DmGame0400A3A01EE4C000.framework",
            bundleID: "org.nxnative.shell.TEAM1",
            deviceUDID: "DEV-1",
            deviceName: "Test iPhone"
        )
        library.updateConnectedDeviceFrameworks([pokopiaTID: devEntry], deviceID: "DEV-1")

        let connectedState = library.artworkState(for: pokopia)
        XCTAssertTrue(connectedState.mac)
        XCTAssertTrue(connectedState.ios)
        XCTAssertEqual(connectedState.chipKey, "library.chip.both")
        XCTAssertTrue(LibraryFilter.ios.includes(pokopia, state: connectedState))
        XCTAssertTrue(BuildInventoryEntry(pokopia, onConnectedDevice: true).installed)

        // Disconnecting restores desktop-only availability without mutating persisted receipt.
        library.updateConnectedDeviceFrameworks([:], deviceID: "")
        XCTAssertFalse(library.artworkState(for: pokopia).ios)
        XCTAssertFalse(library.games[0].installedViaShellReceipt)
        XCTAssertFalse(library.games[1].installedViaShellReceipt)
    }

    func testOnDeviceFrameworkLocalizationsAreValidAndSemicolonFree() {
        let keys = [
            "dev.onDeviceFrameworkBadge",
            "dev.onDeviceFrameworkHelp",
        ]
        for lang in Lang.all {
            for key in keys {
                let text = L10n.string(key, lang)
                XCTAssertNotEqual(text, key, "Missing l10n key \(key) for \(lang.code)")
                XCTAssertFalse(text.contains(";"), "Semicolon forbidden in \(lang.code) \(key)")
                XCTAssertFalse(text.contains("；"), "Fullwidth semicolon forbidden in \(lang.code) \(key)")
            }
        }
    }

    func testCaptureDeviceFrameworkSyncScreenshotsWhenRequested() async throws {
        guard let outDir = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"], !outDir.isEmpty else {
            throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views")
        }
        let outURL = URL(fileURLWithPath: outDir, isDirectory: true)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dfw-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let macApp = try makeMacApp(in: tmp, titleID: pokopiaTID)

        func renderPNG<V: View>(_ view: V, size: CGSize, file: String) throws {
            let wasStatic = LauncherGlass.forceStatic
            LauncherGlass.forceStatic = true
            defer { LauncherGlass.forceStatic = wasStatic }
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).launcherAppearance())
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: outURL.appendingPathComponent(file))
        }

        let phone = AppleDevice(id: "DEV-1", name: "Test iPhone", model: "iPhone 17 Pro", os: "26.0", reachable: true, transport: "wired")
        let entry = DeviceFrameworkEntry(
            titleID: pokopiaTID,
            frameworkName: "DmGame0400A3A01EE4C000.framework",
            bundleID: "org.nxnative.shell.TESTTEAM01",
            deviceUDID: "DEV-1",
            deviceName: "Test iPhone"
        )

        for lang in [Lang.en, Lang.zh] {
            let defaults = TestDefaults.make("dfw-shot-\(lang.code)")
            let loc = Localizer(lang)
            let stores = LauncherStores(localizer: loc, defaults: defaults)
            stores.deviceStore.devices = [phone]
            stores.deviceStore.installDevice = phone.id
            stores.deviceStore.discoverDeviceFrameworks = { udid, name, _ in
                DeviceFrameworkDiscoveryResult(deviceUDID: udid, deviceName: name, bundleID: "org.nxnative.shell.TESTTEAM01", state: .ready, entries: [entry])
            }
            let library = GameLibrary(file: tmp.appendingPathComponent("lib-\(lang.code).json"), artwork: tmp.appendingPathComponent("art-\(lang.code)"))
            var pokopia = LibraryGame(titleID: pokopiaTID, name: "Pokemon Pokopia")
            pokopia.appPath = macApp.path
            library.games = [pokopia]
            library.selectedID = pokopia.id

            // Before: Mac-only without connected device frameworks
            let beforeView = LauncherView(stores: stores, library: library, performStartupChecks: false)
                .environmentObject(loc)
            try renderPNG(beforeView, size: CGSize(width: 1120, height: 740), file: "device-framework-before-\(lang.code).png")

            // After: device framework discovered (On iPhone chip + Mac/iOS status)
            await stores.deviceStore.refreshDeviceFrameworks().value
            library.updateConnectedDeviceFrameworks(stores.deviceStore.deviceFrameworks, deviceID: stores.deviceStore.deviceFrameworksDeviceID)
            let afterView = LauncherView(stores: stores, library: library, performStartupChecks: false)
                .environmentObject(loc)
            try renderPNG(afterView, size: CGSize(width: 1120, height: 740), file: "device-framework-after-\(lang.code).png")
        }
    }
}
