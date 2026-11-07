import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
import NXCore
import NXModel

@MainActor final class BuiltPackageVersionTests: IsolatedDefaultsTestCase {
    private let titleID = "0100000000010000"

    private func makeApp(in directory: URL, version: Any? = "1.2.3", titleID: String? = nil) throws -> URL {
        let app = directory.appendingPathComponent("Marble Orchard.app")
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        for name in ["nxnative", "dmhost"] {
            try FileManager.default.createSymbolicLink(at: executables.appendingPathComponent(name),
                                                      withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        try writeInfo(app, version: version, titleID: titleID)
        return app
    }

    private func writeInfo(_ app: URL, version: Any?, titleID: String? = nil) throws {
        var info: [String: Any] = ["DMTitleID": titleID ?? self.titleID, "CFBundleExecutable": "nxnative",
                                   "CFBundleDisplayName": "Marble Orchard", "CFBundleIdentifier": "org.nxnative.version-tests",
                                   "CFBundleVersion": "999"]
        info["CFBundleShortVersionString"] = version
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
    }

    private func withDirectory(_ run: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nx-version-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try run(directory)
    }

    private func texts(in view: NSView) -> Set<String> {
        var labels: Set<String> = []
        func visit(_ node: NSObject) {
            for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let sel = NSSelectorFromString(selector)
                if node.responds(to: sel), let value = node.perform(sel)?.takeUnretainedValue() as? String { labels.insert(value) }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children), let next = node.perform(children)?.takeUnretainedValue() as? [NSObject] { next.forEach(visit) }
        }
        visit(view.window ?? view)
        return labels
    }

    func testVersionComesFromThePlayableMacPackageAndRefreshesAfterRebuild() throws {
        try withDirectory { directory in
            let app = try makeApp(in: directory, version: " 1.2.3\n")
            var game = LibraryGame(titleID: titleID, name: "Marble Orchard", appPath: app.path,
                                   inputs: ["update": ["newer [v9.9.9].nsp"]])
            let ios = directory.appendingPathComponent("iPhone.app")
            try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "8.0"], format: .xml, options: 0)
                .write(to: ios.appendingPathComponent("Info.plist"))
            game.iosAppPath = ios.path
            game.installedDevice = "TEST-DEVICE"
            XCTAssertEqual(game.primary, .play)
            XCTAssertEqual(game.playVersion, "1.2.3")
            try writeInfo(app, version: "2.0")
            XCTAssertEqual(game.playVersion, "2.0", "Replacing the built app must not leave a cached version")
            try FileManager.default.removeItem(at: app)
            XCTAssertEqual(game.primary, .openOnDevice)
            XCTAssertNil(game.playVersion, "A device's version must not stand in for the missing Mac package")
        }
    }

    func testUnknownVersionAndInvalidMacPackageStayHidden() throws {
        try withDirectory { directory in
            let app = try makeApp(in: directory)
            let game = LibraryGame(titleID: titleID, name: "Marble Orchard", appPath: app.path)
            for version: Any? in [nil, "", " \n\t", 123] {
                try writeInfo(app, version: version)
                XCTAssertTrue(game.isReady)
                XCTAssertNil(game.playVersion, "Never use CFBundleVersion as a game display version")
            }
            try writeInfo(app, version: "1.2.3", titleID: "0100000000020000")
            XCTAssertNil(game.playVersion, "The package belongs to a different game")
            try writeInfo(app, version: "1.2.3")
            try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/dmhost"))
            XCTAssertNil(game.playVersion, "An incomplete app cannot be played")
            XCTAssertNil(LibraryGame(titleID: titleID, name: "Marble Orchard").playVersion)
        }
    }

    func testHeroShowsBuiltMacVersionBesidePlayInEveryLanguage() throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
        try withDirectory { directory in
            let app = try makeApp(in: directory)
            let file = directory.appendingPathComponent("library.json")
            let game = LibraryGame(titleID: titleID, name: "Marble Orchard", appPath: app.path,
                                   inputs: ["base": ["Marble Orchard [0100000000010000].nsp"],
                                            "update": ["Marble Orchard [v9.9.9].nsp"]])
            try JSONEncoder().encode([game]).write(to: file)
            let library = GameLibrary(file: file)
            for code in Lang.all.map(\.code) {
                let stores = LauncherStores(localizer: Localizer(Lang(code)), defaults: testDefaults)
                stores.repo.path = directory.path
                let view = LauncherView(stores: stores, library: library, performStartupChecks: false)
                let host = NSHostingView(rootView: view)
                let window = OffscreenWindow(size: NSSize(width: 900, height: 680))
                window.contentView = host
                window.orderFront(nil)
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                let expected = String(format: stores.localizer.t("console.version"), "1.2.3")
                let deadline = Date().addingTimeInterval(2)
                repeat {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                    host.layoutSubtreeIfNeeded()
                } while !texts(in: host).contains(expected) && Date() < deadline
                if let capture = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] {
                    let output = URL(fileURLWithPath: capture)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: output.appendingPathComponent("mac-version-\(code).png"))
                }
                let visible = texts(in: host)
                XCTAssertTrue(visible.contains(stores.localizer.t("library.play")), "Play in \(code)")
                XCTAssertTrue(visible.contains(expected), "Built version in \(code): \(visible.sorted())")
                XCTAssertFalse(visible.contains { $0.contains("9.9.9") || $0.contains("999") }, "Never show source or build-number versions")
            }
        }
    }
}
