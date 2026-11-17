import Foundation
import XCTest
@testable import NXCore

final class UpstreamEngineStoreTests: XCTestCase {
    private final class FakeTransport: EngineTransport, @unchecked Sendable {
        var archiveToCopy: URL?
        var shouldSucceed = true

        func data(from url: URL) -> EngineFetch<Data> {
            .failed
        }

        func download(from url: URL, to destination: URL) -> Bool {
            download(from: url, to: destination, progress: nil)
        }

        func download(from url: URL, to destination: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) -> Bool {
            guard shouldSucceed, let src = archiveToCopy, let payload = try? Data(contentsOf: src) else {
                return false
            }
            let total = Int64(payload.count)
            progress?(total / 2, total)
            do {
                try payload.write(to: destination)
            } catch {
                return false
            }
            progress?(total, total)
            return true
        }
    }

    private var temporary: URL!
    private var storeRoot: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("upstream-store-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        storeRoot = temporary.appendingPathComponent("upstreams", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeZip(of folder: URL, name: String) throws -> URL {
        let out = temporary.appendingPathComponent(name)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--keepParent", folder.path, out.path]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        return out
    }

    private func makeS2ArmFolder(name: String, complete: Bool) throws -> URL {
        let dir = temporary.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("pack/jobs"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: dir.appendingPathComponent("pack/jobs/main.py"))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("pack/jobs/main.py").path)
        if complete {
            try fm.createDirectory(at: dir.appendingPathComponent("runtime/rewriter"), withIntermediateDirectories: true)
            try Data("/* rewriter */\n".utf8).write(to: dir.appendingPathComponent("runtime/rewriter/rewriter.c"))
            try fm.createDirectory(at: dir.appendingPathComponent("pack/oneclick"), withIntermediateDirectories: true)
            let sh = dir.appendingPathComponent("pack/oneclick/oneclick.sh")
            try Data("#!/bin/bash\n".utf8).write(to: sh)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sh.path)
        }
        return dir
    }

    private func makeMNGFolder(name: String, complete: Bool) throws -> URL {
        let dir = temporary.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("build_app.py")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        if complete {
            try fm.createDirectory(at: dir.appendingPathComponent("games/totk"), withIntermediateDirectories: true)
        }
        return dir
    }

    func testArchiveURLsAndUnsupportedKind() throws {
        XCTAssertNil(UpstreamEngineStore.archiveURL(for: .nxnative))
        XCTAssertNotNil(UpstreamEngineStore.archiveURL(for: .macNativeGames))
        XCTAssertNotNil(UpstreamEngineStore.archiveURL(for: .s2arm))

        let store = UpstreamEngineStore(root: storeRoot)
        XCTAssertNil(store.directory(for: .nxnative))
        XCTAssertNil(store.usableDirectory(for: .nxnative))

        let dummyZip = temporary.appendingPathComponent("dummy.zip")
        try Data("x".utf8).write(to: dummyZip)
        XCTAssertThrowsError(try store.install(zip: dummyZip, kind: .nxnative)) { err in
            XCTAssertEqual(err as? UpstreamEngineStore.Failure, .unsupportedKind)
        }
    }

    func testInstallUnwrapsWrapperSetsExecutableAndCleansTemp() throws {
        let store = UpstreamEngineStore(root: storeRoot)
        let s2Folder = try makeS2ArmFolder(name: "S2Arm-main", complete: true)
        let s2Zip = try makeZip(of: s2Folder, name: "s2arm.zip")

        let installedS2 = try store.install(zip: s2Zip, kind: .s2arm)
        XCTAssertEqual(installedS2.lastPathComponent, EngineUpstreamKind.s2arm.rawValue)
        XCTAssertEqual(store.usableDirectory(for: .s2arm)?.standardizedFileURL, installedS2.standardizedFileURL)
        let shPath = installedS2.appendingPathComponent("pack/oneclick/oneclick.sh").path
        let perms = (try FileManager.default.attributesOfItem(atPath: shPath)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertNotEqual(perms & 0o111, 0)

        let mngFolder = try makeMNGFolder(name: "MacNativeGames-main", complete: true)
        let mngZip = try makeZip(of: mngFolder, name: "mng.zip")
        let installedMNG = try store.install(zip: mngZip, kind: .macNativeGames)
        XCTAssertEqual(store.usableDirectory(for: .macNativeGames)?.standardizedFileURL, installedMNG.standardizedFileURL)

        let hiddenEntries = (try FileManager.default.contentsOfDirectory(atPath: storeRoot.path)).filter { $0.hasPrefix(".") }
        XCTAssertTrue(hiddenEntries.isEmpty)
    }

    func testInstallRejectsIncompleteAndCorruptArchivesPreservingExistingTree() throws {
        let store = UpstreamEngineStore(root: storeRoot)
        let goodZip = try makeZip(of: try makeS2ArmFolder(name: "S2Arm-good", complete: true), name: "good.zip")
        let installed = try store.install(zip: goodZip, kind: .s2arm)
        let marker = installed.appendingPathComponent("marker.txt")
        try Data("keep-existing".utf8).write(to: marker)

        let incompleteZip = try makeZip(of: try makeS2ArmFolder(name: "S2Arm-bad", complete: false), name: "incomplete.zip")
        XCTAssertThrowsError(try store.install(zip: incompleteZip, kind: .s2arm)) { err in
            XCTAssertEqual(err as? UpstreamEngineStore.Failure, .incomplete)
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep-existing")

        let corruptZip = temporary.appendingPathComponent("corrupt.zip")
        try Data("not-a-valid-zip".utf8).write(to: corruptZip)
        XCTAssertThrowsError(try store.install(zip: corruptZip, kind: .s2arm)) { err in
            XCTAssertEqual(err as? UpstreamEngineStore.Failure, .unpack)
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep-existing")

        let hiddenEntries = (try FileManager.default.contentsOfDirectory(atPath: storeRoot.path)).filter { $0.hasPrefix(".") }
        XCTAssertTrue(hiddenEntries.isEmpty)
    }

    func testDownloadAndInstallProgressAndFailure() throws {
        let store = UpstreamEngineStore(root: storeRoot)
        let transport = FakeTransport()
        transport.archiveToCopy = try makeZip(of: try makeS2ArmFolder(name: "S2Arm-dl", complete: true), name: "dl.zip")

        let lock = NSLock()
        var progressCalls = 0
        var sawExtracting = false

        let result = store.downloadAndInstall(
            kind: .s2arm,
            transport: transport,
            onProgress: { _, _ in
                lock.lock()
                progressCalls += 1
                lock.unlock()
            },
            onExtracting: {
                lock.lock()
                sawExtracting = true
                lock.unlock()
            }
        )
        switch result {
        case .success(let url):
            XCTAssertTrue(S2ArmBuilder.isUsableTree(url.path))
        case .failure(let err):
            XCTFail("Expected downloadAndInstall success, got \(err)")
        }
        XCTAssertGreaterThanOrEqual(progressCalls, 2)
        XCTAssertTrue(sawExtracting)

        transport.shouldSucceed = false
        let failed = store.downloadAndInstall(kind: .macNativeGames, transport: transport)
        XCTAssertEqual(failed, .failure(.download))
    }

    func testEngineUpstreamMetadataAndAvailableOnMac() {
        XCTAssertEqual(EngineUpstreamKind.nxnative.displayName, "nxnative")
        XCTAssertEqual(EngineUpstreamKind.macNativeGames.displayName, "MacNativeGames")
        XCTAssertEqual(EngineUpstreamKind.s2arm.displayName, "S2Arm")
        XCTAssertTrue(EngineUpstreamKind.nxnative.isBuiltIn)
        XCTAssertFalse(EngineUpstreamKind.macNativeGames.isBuiltIn)
        XCTAssertFalse(EngineUpstreamKind.s2arm.isBuiltIn)
        XCTAssertEqual(EngineUpstreamKind.nxnative.cardNoteKey, "upstream.nxnativeCardNote")
        XCTAssertEqual(EngineUpstreamKind.macNativeGames.cardNoteKey, "upstream.mngCardNote")
        XCTAssertEqual(EngineUpstreamKind.s2arm.cardNoteKey, "upstream.s2armCardNote")

        XCTAssertEqual(
            EngineUpstream.availableOnMac(macNativeGamesEnabled: true, s2armEnabled: true),
            [.nxnative, .macNativeGames, .s2arm]
        )
        XCTAssertEqual(
            EngineUpstream.availableOnMac(macNativeGamesEnabled: false, s2armEnabled: true),
            [.nxnative, .s2arm]
        )
        XCTAssertEqual(
            EngineUpstream.availableOnMac(macNativeGamesEnabled: false, s2armEnabled: false),
            [.nxnative]
        )
    }

    func testDownloadAndInstallCancellationCleansTemporaryFiles() throws {
        let store = UpstreamEngineStore(root: storeRoot)
        let transport = FakeTransport()
        transport.archiveToCopy = try makeZip(of: try makeS2ArmFolder(name: "S2Arm-cancel", complete: true), name: "cancel.zip")

        let preCancelled = store.downloadAndInstall(kind: .s2arm, transport: transport, shouldCancel: { true })
        XCTAssertEqual(preCancelled, .failure(.cancelled))
        XCTAssertNil(store.usableDirectory(for: .s2arm))

        let cancelMidway = NSLock()
        var cancelledFlag = false
        let midCancelled = store.downloadAndInstall(
            kind: .s2arm,
            transport: transport,
            shouldCancel: {
                cancelMidway.lock()
                defer { cancelMidway.unlock() }
                return cancelledFlag
            },
            onProgress: { _, _ in
                cancelMidway.lock()
                cancelledFlag = true
                cancelMidway.unlock()
            }
        )
        XCTAssertEqual(midCancelled, .failure(.cancelled))
        XCTAssertNil(store.usableDirectory(for: .s2arm))
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: storeRoot.path)) ?? []
        XCTAssertTrue(entries.isEmpty, "Cancelled install must leave zero temporary or partial files: \(entries)")
    }
}
