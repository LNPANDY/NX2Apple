import XCTest
import SwiftUI
import AppKit
@testable import NX2Apple
@testable import NXCore

final class OfflineDataTests: XCTestCase {
    private func temporary(_ test: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try test(root)
    }

    func testSaveInventoryDoesNotModifyFiles() throws {
        try temporary { root in
            let file = root.appendingPathComponent("save.txt")
            try Data("seed".utf8).write(to: file)
            XCTAssertEqual(try OfflineDataInventory.inspect(root, caches: false), OfflineDataInventory(files: 1, bytes: 4))
            XCTAssertEqual(try Data(contentsOf: file), Data("seed".utf8))
        }
    }

    func testCacheDirectoryNames() throws {
        try temporary { root in
            for name in ["SD_Cache.0000", "temp_cache8"] {
                let dir = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data([1, 2]).write(to: dir.appendingPathComponent("data"))
            }
            XCTAssertEqual(try OfflineDataInventory.inspect(root, caches: true), OfflineDataInventory(files: 2, bytes: 4))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("SD_CacheX0001"), withIntermediateDirectories: true)
            XCTAssertThrowsError(try OfflineDataInventory.inspect(root, caches: true))
        }
    }

    func testIndicesAreBoundedAndAliasesCannotCollide() throws {
        XCTAssertEqual(OfflineDataInventory.cacheIndex("SD_Cache.0008"), 8)
        XCTAssertNil(OfflineDataInventory.cacheIndex("temp_cache65536"))
        XCTAssertNil(OfflineDataInventory.cacheIndex("temp_cache-1"))
        try temporary { root in
            for name in ["SD_Cache.0000", "temp_cache0"] {
                let dir = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data([1]).write(to: dir.appendingPathComponent("data"))
            }
            XCTAssertThrowsError(try OfflineDataInventory.inspect(root, caches: true))
        }
    }

    func testStageNormalizesCachesAndNeverOverwrites() throws {
        try temporary { root in
            let save = root.appendingPathComponent("source-save")
            let caches = root.appendingPathComponent("source-cache")
            let cache = caches.appendingPathComponent("SD_Cache.0008")
            try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data("progress".utf8).write(to: save.appendingPathComponent("save.txt"))
            try Data([1, 2, 3]).write(to: cache.appendingPathComponent("payload"))
            let output = root.appendingPathComponent("seed")
            try OfflineDataInventory.stage(save: save, caches: caches, destination: output)
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("save/save.txt")), Data("progress".utf8))
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("temp_cache8/payload")), Data([1, 2, 3]))
            XCTAssertThrowsError(try OfflineDataInventory.stage(save: save, caches: caches, destination: output))
            XCTAssertEqual(try Data(contentsOf: save.appendingPathComponent("save.txt")), Data("progress".utf8))
        }
    }

    @MainActor func testRenderOfflineControlsForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let view = OfflineDataView(t: { L10n.string($0, .en) }, saveFolder: .constant("/Example/Backup/Save"), cacheFolder: .constant("/Example/Backup/Cache Data"))
            .padding(24).frame(width: 840).preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        let rendered = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(rendered.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("offline-controls-rendered.png"))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("offline-controls-after.png"))
    }

    func testPackagingWritesPortableEntryAndRefusesSecondImport() throws {
        try temporary { root in
            let app = root.appendingPathComponent("Game.app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            let plist = contents.appendingPathComponent("Info.plist")
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "nxnative", "CFBundleIdentifier": "org.example.game"], format: .xml, options: 0).write(to: plist)
            let save = root.appendingPathComponent("save")
            try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
            try Data([7]).write(to: save.appendingPathComponent("progress"))
            try OfflineAppSeed.install(app: app, save: save, caches: nil)
            let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: nil) as? [String: String])
            XCTAssertEqual(info["CFBundleExecutable"], "offline-launch")
            XCTAssertEqual(try Data(contentsOf: contents.appendingPathComponent("Resources/offline-seed/save/progress")), Data([7]))
            let script = try String(contentsOf: contents.appendingPathComponent("MacOS/offline-launch"), encoding: .utf8)
            XCTAssertTrue(script.contains("org.example.game"))
            XCTAssertFalse(script.contains(root.path))
            XCTAssertTrue(script.contains("export DM_SAVE_SYNC=0"))
            XCTAssertThrowsError(try OfflineAppSeed.install(app: app, save: save, caches: nil))
        }
    }

    func testPortableLauncherPreservesProgressAcrossStarts() throws {
        try temporary { root in
            let mac = root.appendingPathComponent("Example.app/Contents/MacOS")
            let seed = root.appendingPathComponent("Example.app/Contents/Resources/offline-seed/save")
            try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: seed.appendingPathComponent("progress"))
            let wrapper = mac.appendingPathComponent("offline-launch")
            try OfflineAppSeed.launcher(identifier: "org.example.game").write(to: wrapper, atomically: true, encoding: .utf8)
            let host = mac.appendingPathComponent("nxnative")
            try "#!/bin/sh\ntest -f \"$DM_SAVE/progress\"\n".write(to: host, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
            func launch() throws -> Int32 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [wrapper.path]
                process.environment = ProcessInfo.processInfo.environment.merging(["HOME": root.appendingPathComponent("home").path]) { _, new in new }
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }
            XCTAssertEqual(try launch(), 0)
            let progress = root.appendingPathComponent("home/Library/Application Support/nxnative/offline/org.example.game/save/progress")
            try Data("new-progress".utf8).write(to: progress)
            XCTAssertEqual(try launch(), 0)
            XCTAssertEqual(try Data(contentsOf: progress), Data("new-progress".utf8))
        }
    }

    func testCancellationNeverPublishesSeed() throws {
        try temporary { root in
            let save = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
            try Data([1]).write(to: save.appendingPathComponent("progress"))
            let destination = root.appendingPathComponent("seed")
            XCTAssertThrowsError(try OfflineDataInventory.stage(save: save, caches: nil, destination: destination, cancelled: { true }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source"])
        }
    }

    @MainActor func testRenderFullOfflineBuildForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Opt-in screenshot") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stores = LauncherStores()
        stores.build.target = BuildTarget.mac
        stores.build.lang = CaptureLanguage.current(.en)
        stores.build.offlineSaveFolder = "/Example/Backup/Save"
        stores.build.offlineCacheFolder = "/Example/Backup/Cache Data"
        let library = GameLibrary(file: output.appendingPathComponent("synthetic-library.json"))
        let host = NSHostingView(rootView: LauncherView(stores: stores, library: library, initialPage: .builds, performStartupChecks: false))
        let window = OffscreenWindow(size: NSSize(width: 1440, height: 1400), styleMask: [.titled, .closable, .resizable])
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("offline-build-after-" + stores.build.lang.code + ".png"))
    }

    func testUnsafeBundleIdentifierRejectedBeforeCopy() throws {
        try temporary { root in
            let app = root.appendingPathComponent("Game.app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            let save = root.appendingPathComponent("save")
            try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
            try Data([1]).write(to: save.appendingPathComponent("progress"))
            for identifier in ["..", "org..game", "../game", ""] {
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "nxnative", "CFBundleIdentifier": identifier], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
                XCTAssertThrowsError(try OfflineAppSeed.install(app: app, save: save, caches: nil))
                XCTAssertFalse(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Resources/offline-seed").path))
            }
        }
    }

    func testFinalizationFailureRestoresAppEntryPoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Game.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let plist = contents.appendingPathComponent("Info.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "nxnative", "CFBundleIdentifier": "org.example.game"], format: .xml, options: 0)
        try original.write(to: plist)
        let save = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        try Data([1]).write(to: save.appendingPathComponent("progress"))
        XCTAssertThrowsError(try OfflineAppSeed.install(app: app, save: save, caches: nil, finalize: { throw CocoaError(.fileWriteUnknown) }))
        XCTAssertEqual(try Data(contentsOf: plist), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: contents.appendingPathComponent("MacOS/offline-launch").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Resources/offline-seed").path))
    }

    func testFailedCandidateSigningCannotModifyOriginalApp() throws {
        try temporary { root in
            let app = root.appendingPathComponent("Game.app")
            let mac = app.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let original = Data("original-executable".utf8)
            try original.write(to: mac.appendingPathComponent("nxnative"))
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "nxnative", "CFBundleIdentifier": "org.example.game"], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            let save = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
            try Data([1]).write(to: save.appendingPathComponent("progress"))
            XCTAssertThrowsError(try OfflineAppSeed.prepareCopy(app: app, save: save, caches: nil, finalize: { staged in
                try Data("partially-signed".utf8).write(to: staged.appendingPathComponent("Contents/MacOS/nxnative"))
                throw CocoaError(.fileWriteUnknown)
            }))
            XCTAssertEqual(try Data(contentsOf: mac.appendingPathComponent("nxnative")), original)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".offline-candidate-") })
        }
    }

    func testPartialAppCopyIsRemovedAndOriginalPreserved() throws {
        try temporary { root in
            let app = root.appendingPathComponent("Game.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try Data([1, 2]).write(to: app.appendingPathComponent("original"))
            XCTAssertThrowsError(try OfflineAppSeed.prepareCopy(app: app, save: nil, caches: nil, copyApp: { _, candidate in
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                try Data([3]).write(to: candidate.appendingPathComponent("partial"))
                throw CocoaError(.fileWriteOutOfSpace)
            }, finalize: { _ in XCTFail("Must not sign a failed copy") }))
            XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("original")), Data([1, 2]))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".offline-candidate-") })
        }
    }

    func testSymlinkInsertedAfterInventoryIsNeverPublished() throws {
        try temporary { root in
            let save = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
            try Data([1]).write(to: save.appendingPathComponent("progress"))
            let outside = root.appendingPathComponent("outside")
            try Data([2]).write(to: outside)
            let destination = root.appendingPathComponent("seed")
            var inserted = false
            XCTAssertThrowsError(try OfflineDataInventory.stage(save: save, caches: nil, destination: destination, cancelled: {
                if !inserted {
                    inserted = true
                    try! FileManager.default.createSymbolicLink(at: save.appendingPathComponent("late-link"), withDestinationURL: outside)
                }
                return false
            }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try Data(contentsOf: outside), Data([2]))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".offline-seed-") })
        }
    }

    func testFailedPublicationRestoresMissingOriginalAndKeepsCandidate() throws {
        try temporary { root in
            let fm = FileManager.default
            let app = root.appendingPathComponent("Game.app")
            let candidate = root.appendingPathComponent("candidate.app")
            for folder in [app, candidate] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            try Data([1]).write(to: app.appendingPathComponent("original"))
            XCTAssertThrowsError(try OfflineAppSeed.publish(candidate: candidate, over: app, replace: { original, _, backup in
                try fm.moveItem(at: original, to: root.appendingPathComponent(backup))
                throw CocoaError(.fileWriteUnknown)
            }))
            XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("original")), Data([1]))
            XCTAssertTrue(fm.fileExists(atPath: candidate.path))
        }
    }

    func testFailedPublicationNeverOverwritesConcurrentDestination() throws {
        try temporary { root in
            let fm = FileManager.default
            let app = root.appendingPathComponent("Game.app")
            let candidate = root.appendingPathComponent("candidate.app")
            for folder in [app, candidate] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            try Data([1]).write(to: app.appendingPathComponent("original"))
            var retainedBackup: URL?
            XCTAssertThrowsError(try OfflineAppSeed.publish(candidate: candidate, over: app, replace: { original, _, backup in
                let saved = root.appendingPathComponent(backup)
                retainedBackup = saved
                try fm.moveItem(at: original, to: saved)
                try fm.createDirectory(at: original, withIntermediateDirectories: true)
                try Data([2]).write(to: original.appendingPathComponent("concurrent"))
                throw CocoaError(.fileWriteUnknown)
            }))
            let backup = try XCTUnwrap(retainedBackup)
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("original")), Data([1]))
            XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("concurrent")), Data([2]))
            XCTAssertFalse(fm.fileExists(atPath: app.appendingPathComponent("original").path))
            XCTAssertTrue(fm.fileExists(atPath: candidate.path))
        }
    }

    func testInventoryCancellationStopsDuringTraversal() throws {
        try temporary { root in
            for i in 0..<8 { try Data([1]).write(to: root.appendingPathComponent("file-\(i)")) }
            var checks = 0
            XCTAssertThrowsError(try OfflineDataInventory.inspect(root, caches: false, cancelled: {
                checks += 1
                return checks == 3
            })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(checks, 3)
        }
    }

    func testNamedPipeRejectedBeforeCopy() throws {
        try temporary { root in
            try Data([1]).write(to: root.appendingPathComponent("regular"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
            process.arguments = [root.appendingPathComponent("pipe").path]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertThrowsError(try OfflineDataInventory.inspect(root, caches: false))
        }
    }

    func testEmptyAndSymlinkRejected() throws {
        try temporary { root in
            XCTAssertThrowsError(try OfflineDataInventory.inspect(root, caches: false))
            let target = root.appendingPathComponent("target")
            try Data([1]).write(to: target)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
            XCTAssertThrowsError(try OfflineDataInventory.inspect(root, caches: false))
        }
    }
}
