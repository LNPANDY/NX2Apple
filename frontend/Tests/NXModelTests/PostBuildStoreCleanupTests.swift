import Combine
import XCTest
@testable import NXModel
@testable import NXCore

@MainActor final class PostBuildStoreCleanupTests: XCTestCase {
    private final class FakeRepo: RepoLocation {
        var path = "/repo"
        var isRepo = true
        var isGit = true
    }

    private final class FakeDeps: DependencyInstalling {
        var pythonPath = "/usr/bin/python3"
        var dotnetPath = "/usr/bin/true"
        var checked = true
        var allPresent = true
        var deps: [Dep] = []
        func isInstalling(_ id: String) -> Bool { false }
        func install(_ dep: Dep) -> Task<Void, Never> { Task {} }
    }

    private final class FakeEngine: EngineSyncing {
        func syncEngine(then: ((Bool) -> Void)?) -> Task<Void, Never> { then?(true); return Task {} }
    }

    private final class FakeDevices: InstallTarget {
        var installDevice = ""
        var signingTeam = ""
        var exportIPA = false
        var exportOneGame = false
        var driveFolder = ""
        var devices: [AppleDevice] = []
        var xcrun = "/usr/bin/true"
        var readTeams: @Sendable () -> [SigningTeam] = { [] }
        func deviceName(_ udid: String) -> String { "iPhone" }
        nonisolated func askCopy(_ plan: ShellCopyPlan) -> ShellCopyDecision { .skip }
        nonisolated func setWaiting(_ on: Bool) {}
        nonisolated var waitCancelled: Bool { false }
        func copyEnded() {}
    }

    private var defaults: UserDefaults!
    private var temporary: URL!
    private let fm = FileManager.default
    private let repo = FakeRepo()
    private let deps = FakeDeps()
    private let engine = FakeEngine()
    private let devices = FakeDevices()

    override func setUpWithError() throws {
        defaults = TestDefaults.make("nxmodel-post-build-cleanup")
        temporary = fm.temporaryDirectory.appendingPathComponent("nxmodel-cleanup-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: temporary)
    }

    private func makeStore(runner: ProcessRunner = FakeProcessRunner()) -> BuildStore {
        let store = BuildStore(localizer: Localizer(.en), runner: runner, repo: repo, deps: deps, engine: engine,
                               devices: devices, defaults: defaults)
        store.home = temporary.appendingPathComponent("home").path
        store.outDir = temporary.appendingPathComponent("out").path
        return store
    }

    private func write(_ rel: String, in base: URL? = nil, _ text: String = "data") throws -> String {
        let url = (base ?? temporary).appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    func testFinishMacAppCleansWorkDirectoryAfterPlacingApp() async throws {
        let id = "0100000000010000"
        let store = makeStore()
        defaults.set(false, forKey: MacPreflight.defaultsKey)
        let out = temporary.appendingPathComponent("out")
        let work = out.appendingPathComponent(id + "_build")
        let output = MacAppOutput(workDir: work, key: id, titleID: id, preferred: "")
        for (name, content) in [("game", ""), ("dmhost", "")] {
            let p = try write("Contents/MacOS/" + name, in: output.builderURL, content)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
        }
        let info: [String: Any] = ["DMTitleID": id, "CFBundleExecutable": "game", "CFBundleName": "Odyssey"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: output.builderURL.appendingPathComponent("Contents/Info.plist"))
        _ = try write("Contents/Resources/romfs.img", in: output.builderURL, "packed-image")
        _ = try write("Contents/Resources/romfs.img.id", in: output.builderURL, "{\"title\":\"\(id.lowercased())\"}\n")

        _ = try write("nsp/base.nsp", in: work)
        _ = try write("extract/v0/RomFS.img", in: work)
        _ = try write("extract/v0/ExeFS/main", in: work)
        _ = try write("pso/mac-work/batches.applegpu_g15g/0/a.mtl4a", in: work)
        _ = try write("pso/mac-work/key.applegpu_g15g", in: work)

        store.running = true
        await store.finishMacApp(output).value

        XCTAssertTrue(store.done)
        XCTAssertEqual(store.macAppPath, out.appendingPathComponent("Odyssey.app").path)
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("nsp").path))
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("extract/v0/RomFS.img").path))
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("pso/mac-work/batches.applegpu_g15g").path))
        XCTAssertTrue(fm.fileExists(atPath: work.appendingPathComponent("extract/v0/ExeFS/main").path))
        XCTAssertTrue(fm.fileExists(atPath: work.appendingPathComponent("pso/mac-work/key.applegpu_g15g").path))
        XCTAssertEqual(
            RomFSArchive.reusableImages(root: out.path, key: id),
            [out.appendingPathComponent("Odyssey.app/Contents/Resources/romfs.img").path]
        )
    }

    func testFinishOneGameIPACleansWorkDirectoryOnlyWhenIPAExists() throws {
        let id = "0100000000010000"
        let store = makeStore()
        let work = temporary.appendingPathComponent("out/\(id)_build")
        _ = try write("nsp/base.nsp", in: work)
        _ = try write("extract/v0/RomFS.img", in: work)
        store.effectiveWorkDir = work.path
        store.oneGameIPAPath = temporary.appendingPathComponent("out/\(id).ipa").path

        let missingEnded = expectation(description: "missing IPA")
        let sub1 = store.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in missingEnded.fulfill() }
        store.finishOneGameIPA()
        wait(for: [missingEnded], timeout: 5)
        withExtendedLifetime(sub1) {}
        XCTAssertFalse(store.done)
        XCTAssertTrue(fm.fileExists(atPath: work.appendingPathComponent("extract/v0/RomFS.img").path),
                      "failed export must not wipe extracted files")

        _ = try write("out/\(id).ipa", "ipa-bytes")
        let madeEnded = expectation(description: "made IPA")
        let sub2 = store.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in madeEnded.fulfill() }
        store.finishOneGameIPA()
        wait(for: [madeEnded], timeout: 5)
        withExtendedLifetime(sub2) {}
        XCTAssertTrue(store.done)
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("nsp").path))
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("extract/v0/RomFS.img").path))
    }

    func testPackArchiveMovesNewestImageDeletesOlderExtractedImagesAndKeepsShellFrameworkForNextStep() throws {
        let id = "0100535012974000"
        let store = makeStore()
        let work = temporary.appendingPathComponent("out/\(id)_build")
        _ = try write("nsp/base.nsp", in: work)
        _ = try write("extract/v0/RomFS.img", in: work, "base-only")
        _ = try write("extract/v0/ExeFS/main", in: work)
        _ = try write("extract/v65536/RomFS.img", in: work, "merged-image")
        _ = try write("extract/v65536/RomFS.img.id", in: work, "{\"title\":\"\(id.lowercased())\"}\n")
        _ = try write("extract/v65536/ExeFS/main", in: work)
        _ = try write("aoc/0.img", in: work, "dlc0")
        _ = try write("aoc.key", in: work, "key")
        _ = try write("shell-framework/DmGame\(id).framework/game.manifest.json", in: work, "{}")

        var archiveDest = ""
        let doneExp = expectation(description: "packArchive")
        store.packArchive(workDir: work.path, titleID: id) { dest in
            archiveDest = dest
            doneExp.fulfill()
        }
        wait(for: [doneExp], timeout: 5)

        XCTAssertEqual(archiveDest, temporary.appendingPathComponent("out/games/\(id)").path)
        XCTAssertEqual(try String(contentsOfFile: archiveDest + "/romfs.img", encoding: .utf8), "merged-image")
        XCTAssertEqual(try String(contentsOfFile: archiveDest + "/romfs.img.id", encoding: .utf8), "{\"title\":\"\(id.lowercased())\"}\n")
        XCTAssertEqual(try String(contentsOfFile: archiveDest + "/aoc/0.img", encoding: .utf8), "dlc0")
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("extract/v65536/RomFS.img").path))
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("extract/v0/RomFS.img").path))
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("nsp").path))
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("aoc").path))
        XCTAssertTrue(fm.fileExists(atPath: work.appendingPathComponent("extract/v65536/ExeFS/main").path))
        XCTAssertTrue(fm.fileExists(atPath: work.appendingPathComponent("shell-framework/DmGame\(id).framework/game.manifest.json").path))
    }

    func testDeferredShellExportCleansExportProductsAndStagedFrameworksOnlyAfterExportSucceeds() throws {
        guard fm.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required") }
        let id1 = "0100535012974000"
        let id2 = "01007EF00011E000"
        let xcrun = try write("xcrun", """
        #!/usr/bin/python3
        import os, sys
        a = sys.argv[1:]
        def val(flag): return a[a.index(flag) + 1] if flag in a else None
        if a[0] == 'xcodebuild':
            if os.path.exists('\(temporary.path)/fail-xcode'):
                print('error: xcodebuild failed', flush=True)
                sys.exit(65)
            dd = val('-derivedDataPath')
            app = dd + '/Build/Products/Release-iphoneos/DmShell.app'
            os.makedirs(dd + '/Build/Intermediates.noindex/DmShell.build', exist_ok=True)
            open(dd + '/Build/Intermediates.noindex/DmShell.build/main.o', 'w').write('obj')
            os.makedirs(app + '/Frameworks', exist_ok=True)
            open(app + '/DmShell', 'w').write('exe')
            open(app + '/Info.plist', 'w').write('plist')
            sys.exit(0)
        sys.exit(0)
        """)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun)

        let fakeRepo = temporary.appendingPathComponent("repo")
        let shellSh = try write("frontend-ios/Shell/build_shell.sh", in: fakeRepo, """
        #!/bin/bash
        mkdir -p "$SHELL_DIR/DmShell.xcodeproj" "$SHELL_DIR/Gen"
        exit 0
        """)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellSh)
        _ = try write("frontend-ios/Package.swift", in: fakeRepo, "// swift-tools-version: 5.9\n")

        repo.path = fakeRepo.path
        devices.xcrun = xcrun
        devices.exportIPA = true
        let store = makeStore(runner: SystemProcessRunner())
        let shellRoot = store.shellRoot
        _ = try write("derived-data/Build/Products/Release-iphoneos/DmShell.app/embedded.mobileprovision",
                      in: URL(fileURLWithPath: shellRoot), "signed")

        let fw1 = temporary.appendingPathComponent("out/\(id1)_build/shell-framework/DmGame\(id1).framework")
        let fw2 = temporary.appendingPathComponent("out/\(id2)_build/shell-framework/DmGame\(id2).framework")
        for (id, fw) in [(id1, fw1), (id2, fw2)] {
            _ = try write("game.manifest.json", in: fw, "{}")
            _ = try write("DmGame\(id)", in: fw, "bin")
        }

        // First attempt fails xcodebuild: staged shell-framework directories stay so retry can still mirror or inspect them.
        _ = try write("fail-xcode", "1")
        store.deferShellPackage(framework: fw1.path, titleID: id1, name: "Hades")
        store.deferShellPackage(framework: fw2.path, titleID: id2, name: "BotW")
        XCTAssertTrue(fm.fileExists(atPath: fw1.path))
        XCTAssertTrue(fm.fileExists(atPath: fw2.path))

        let failedExp = expectation(description: "failed export")
        let sub1 = store.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in failedExp.fulfill() }
        store.packageDeferred()
        wait(for: [failedExp], timeout: 10)
        withExtendedLifetime(sub1) {}
        XCTAssertFalse(store.done)
        XCTAssertTrue(fm.fileExists(atPath: fw1.deletingLastPathComponent().path))
        XCTAssertTrue(fm.fileExists(atPath: fw2.deletingLastPathComponent().path))

        // Retry succeeds: export Products and staged shell-framework containers go, while mirrored frameworks and signed DmShell.app stay.
        try fm.removeItem(atPath: temporary.appendingPathComponent("fail-xcode").path)
        store.deferShellPackage(framework: fw1.path, titleID: id1, name: "Hades")
        store.deferShellPackage(framework: fw2.path, titleID: id2, name: "BotW")
        let okExp = expectation(description: "ok export")
        let sub2 = store.$running.dropFirst().filter { !$0 }.prefix(1).sink { _ in okExp.fulfill() }
        store.packageDeferred()
        wait(for: [okExp], timeout: 10)
        withExtendedLifetime(sub2) {}

        XCTAssertTrue(store.done, store.doneNote)
        XCTAssertTrue(fm.fileExists(atPath: ShellInstall.ipaPath(root: shellRoot)))
        XCTAssertFalse(fm.fileExists(atPath: ShellInstall.exportDerivedData(root: shellRoot) + "/Build/Products"))
        XCTAssertTrue(fm.fileExists(atPath: ShellInstall.exportDerivedData(root: shellRoot) + "/Build/Intermediates.noindex/DmShell.build/main.o"))
        XCTAssertTrue(fm.fileExists(atPath: shellRoot + "/derived-data/Build/Products/Release-iphoneos/DmShell.app/embedded.mobileprovision"))
        XCTAssertTrue(fm.fileExists(atPath: shellRoot + "/frameworks/DmGame\(id1).framework/game.manifest.json"))
        XCTAssertTrue(fm.fileExists(atPath: shellRoot + "/frameworks/DmGame\(id2).framework/game.manifest.json"))
        XCTAssertFalse(fm.fileExists(atPath: fw1.deletingLastPathComponent().path))
        XCTAssertFalse(fm.fileExists(atPath: fw2.deletingLastPathComponent().path))
    }
}
