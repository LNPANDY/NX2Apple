import Foundation
import XCTest
#if canImport(SwiftUI)
import Combine
#endif
#if canImport(NSPortBuilder)
@testable import NSPortBuilder
#endif

final class PackageCheckTests: XCTestCase {
    let base: UInt64 = 0x0100000000010000
    var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".package-check-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func package(_ name: String, title: UInt64? = nil, xci: Bool = false) throws -> String {
        let url = root.appendingPathComponent(name)
        var data = Data()
        func number(_ value: UInt64, _ count: Int) {
            for i in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
        }
        if xci { data = Data(repeating: 0, count: 0x100); data.append(contentsOf: "HEAD".utf8) }
        else {
            let name = title.map { String(format: "%016llX0000000000000000.tik", $0) + "\0" } ?? ""
            data.append(contentsOf: "PFS0".utf8)
            number(title == nil ? 0 : 1, 4); number(UInt64(name.utf8.count), 4); number(0, 4)
            if title != nil { data.append(Data(repeating: 0, count: 24)); data.append(contentsOf: name.utf8) }
        }
        try data.write(to: url)
        return url.path
    }

    func testTicketPriorityAndFilenameFallback() throws {
        let ticket = try package("wrong [0100000000010001].nsp", title: base)
        let result = PackageCheck.run([ticket, ""])
        XCTAssertTrue(result.ready)
        XCTAssertEqual(result.title, base)
        XCTAssertEqual(result.packages[0].method, "ticket name")
        let named = try package(String(format: "game [%016llX].xci", base), xci: true)
        XCTAssertEqual(PackageCheck.inspect(named).title, base)
        XCTAssertEqual(PackageCheck.inspect(named).method, "filename tag")
    }

    func testTicketlessBaseWithAutomaticUpdate() throws {
        let path = try package("cartridge.xci", xci: true)
        let update = try package("patch.nsp", title: base + 0x800)
        let result = PackageCheck.run([path, ""])
        XCTAssertTrue(result.ready)
        XCTAssertEqual(result.title, base)
        XCTAssertTrue(result.paths.contains(update))
        XCTAssertTrue(result.packages[0].method.contains("ticketless base"))
        _ = try package("ambiguous.nsp")
        XCTAssertFalse(PackageCheck.run([path, ""]).ready)
    }

    func testUnknownMalformedAndMissingAreNotKeysFailures() throws {
        let path = try package("unknown.nsp")
        XCTAssertEqual(PackageCheck.inspect(path).reason, PackageCheck.missingID)
        XCTAssertFalse(PackageCheck.run([path, ""]).ready)
        try Data("PFS0".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(PackageCheck.inspect(path).reason.contains("Malformed"))
        try FileManager.default.removeItem(atPath: path)
        XCTAssertTrue(PackageCheck.inspect(path).reason.contains("missing"))
    }

    func testUnboundedOrOverflowingTableIsRejected() throws {
        let path = try package("bad.nsp")
        var data = Data("PFS0".utf8)
        data.append(Data(repeating: 255, count: 12))
        try data.write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(PackageCheck.inspect(path).reason.contains("Malformed"))
        data = Data("PFS0".utf8)
        data.append(contentsOf: [1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
        data.append(Data(repeating: 255, count: 24)); data.append(0)
        try data.write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(PackageCheck.inspect(path).reason.contains("Malformed"))
    }

    func testRolesForeignGamesAndAutomaticDLC() throws {
        let path = try package("base.nsp", title: base)
        let update = try package("update.nsp", title: base + 0x800)
        let dlc = try package("dlc.nsp", title: base + 0x1001)
        let foreign = try package("foreign.nsp", title: base + 0x100800)
        XCTAssertFalse(PackageCheck.run([update, ""]).ready)
        let mismatched = PackageCheck.run([path, foreign])
        XCTAssertTrue(mismatched.packages[1].reason.contains("different game"))
        let result = PackageCheck.run([path, ""])
        XCTAssertTrue(result.ready)
        XCTAssertEqual(Set(result.paths), Set([path, update, dlc]))
        XCTAssertTrue(result.needsStaging)
        XCTAssertFalse(result.diagnostics.contains(root.path))
        XCTAssertFalse(result.diagnostics.contains("base.nsp"))
    }

    func testDecompressedCounterpartWins() throws {
        let decompressed = try package("base.nsp", title: base)
        let compressed = try package("base.nsz", title: base + 0x100800)
        let result = PackageCheck.run([compressed, ""])
        XCTAssertTrue(result.ready)
        XCTAssertEqual(result.title, base)
        XCTAssertEqual(result.paths, [decompressed])
        XCTAssertTrue(result.packages.last!.method.contains("skipped"))
    }

    func testSelectedCompressedDLCDeduplicatesEffectivePaths() throws {
        let path = try package("base.nsp", title: base)
        let dlc = try package("addon.nsp", title: base + 0x1001)
        let compressed = try package("addon.nsz", title: base + 0x1001)
        for selected in [[dlc, compressed], [compressed, dlc]] {
            let result = PackageCheck.run([path, ""] + selected)
            XCTAssertTrue(result.ready, result.diagnostics)
            XCTAssertEqual(result.paths, [path, dlc])
            XCTAssertEqual(result.packages.filter { !$0.consumed }.count, 1)
            XCTAssertTrue(result.diagnostics.contains("skipped"))
        }
    }

    func testRealBasenameCollisionsStillFail() throws {
        let path = try package("base.nsp", title: base)
        let dlc = try package("addon.nsp", title: base + 0x1001)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
        let collision = try package("other/addon.nsp", title: base + 0x1001)
        let result = PackageCheck.run([path, "", dlc, collision])
        XCTAssertFalse(result.ready)
        XCTAssertTrue(result.packages[0].reason.contains("duplicate names"))
    }

    func testStagingUsesWritableOutputInsteadOfReadOnlySource() throws {
        let source = root.appendingPathComponent("library")
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let path = try package("library/base.nsp", title: base)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path) }
        let staged = try PackageCheck.stage([path], in: output.path)
        defer { try? FileManager.default.removeItem(atPath: staged) }
        XCTAssertEqual(URL(fileURLWithPath: staged).deletingLastPathComponent().path, output.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staged), ["base.nsp"])
        XCTAssertEqual(PackageCheck.inspect(staged + "/base.nsp").title, base)
    }

    func testPartialStagingIsRemovedOnFailure() throws {
        let path = try package("base.nsp", title: base)
        let output = root.appendingPathComponent("output")
        let fallback = root.appendingPathComponent("fallback")
        XCTAssertThrowsError(try PackageCheck.stage([path, path], in: output.path, fallbackFolder: fallback.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fallback.path), [])
    }

    func testStagingFallsBackWhenOutputFilesystemCannotCreateSymlinks() throws {
        let paths = try [package("base.nsp", title: base), package("update.nsp", title: base + 0x800)]
        let output = root.appendingPathComponent("output")
        let fallback = root.appendingPathComponent("fallback")
        let fm = UnsupportedSymlinkFileManager()
        fm.unsupportedParent = output.path
        let staged = try PackageCheck.stage(paths, in: output.path, fallbackFolder: fallback.path, fileManager: fm)
        defer { try? fm.removeItem(atPath: staged) }
        XCTAssertEqual(URL(fileURLWithPath: staged).deletingLastPathComponent().path, fallback.path)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: output.path), [])
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: staged)), Set(["base.nsp", "update.nsp"]))
        for path in paths {
            let link = staged + "/" + (path as NSString).lastPathComponent
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link), path)
            XCTAssertEqual(PackageCheck.inspect(link).title, PackageCheck.inspect(path).title)
        }
        // The build's writable output remains on the selected drive, not beside the fallback links.
        try Data().write(to: output.appendingPathComponent("build-output"))
        try fm.removeItem(atPath: staged)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: fallback.path), [])
        XCTAssertTrue(paths.allSatisfy { fm.fileExists(atPath: $0) })
    }

    private final class UnsupportedSymlinkFileManager: FileManager, @unchecked Sendable {
        var unsupportedParent = ""

        override func createSymbolicLink(atPath path: String, withDestinationPath destination: String) throws {
            // Leave one successful link to exercise cleanup of partially staged input.
            if path.hasPrefix(unsupportedParent + "/"), path.hasSuffix("/update.nsp") {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EOPNOTSUPP.rawValue))
            }
            try super.createSymbolicLink(atPath: path, withDestinationPath: destination)
        }
    }

    #if canImport(SwiftUI)
    @MainActor func testOldBuildPreflightDoesNotInvalidateNewSelectionCheck() async throws {
        let model = BuildModel()
        model.repoPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let checks = ControlledPackageChecks()
        model.inspectPackages = { await checks.run($0) }
        model.slots[0].paths = ["old.nsp"]
        model.startBuild()
        await waitUntil { await checks.count == 1 }
        model.slots[0].paths = ["new.nsp"]
        let preview = Task { await model.checkPackages() }
        await waitUntil { await checks.count == 2 }
        await checks.finish(0, result: PackageCheck.Result())
        await waitUntil { !model.preparingBuild }
        XCTAssertTrue(model.checkingPackages, "the newer selection check still owns the spinner")
        var latest = PackageCheck.Result()
        latest.title = base + 0x100000
        await checks.finish(1, result: latest)
        await preview.value
        XCTAssertEqual(model.packageInputs, model.selectedPackages)
        XCTAssertEqual(model.packageCheck.title, latest.title)
        XCTAssertFalse(model.checkingPackages)
    }

    @MainActor func testLatestSameSelectionCheckWinsAndPublishesOnMainThread() async {
        let model = BuildModel()
        model.slots[0].paths = ["same.nsp"]
        let checks = ControlledPackageChecks()
        model.inspectPackages = { await checks.run($0) }
        let publication = model.$packageCheck.dropFirst().sink { _ in
            XCTAssertTrue(Thread.isMainThread)
        }
        let old = Task { await model.checkPackages() }
        await waitUntil { await checks.count == 1 }
        let latest = Task { await model.checkPackages() }
        await waitUntil { await checks.count == 2 }
        var result = PackageCheck.Result()
        result.title = base
        await checks.finish(1, result: result)
        await latest.value
        await checks.finish(0, result: PackageCheck.Result())
        await old.value
        XCTAssertEqual(model.packageCheck.title, base)
        XCTAssertFalse(model.checkingPackages)
        withExtendedLifetime(publication) {}
    }

    @MainActor private func waitUntil(_ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let finished = await condition()
        XCTAssertTrue(finished)
    }
    #endif
}

#if canImport(SwiftUI)
private actor ControlledPackageChecks {
    private var requests: [CheckedContinuation<PackageCheck.Result, Never>] = []
    var count: Int { requests.count }

    func run(_ inputs: [String]) async -> PackageCheck.Result {
        await withCheckedContinuation { requests.append($0) }
    }

    func finish(_ index: Int, result: PackageCheck.Result) {
        requests[index].resume(returning: result)
    }
}
#endif
