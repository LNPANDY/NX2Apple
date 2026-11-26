import Foundation
import XCTest
@testable import NXCore

final class KidWithSwordCompatTests: XCTestCase {
    private let fm = FileManager.default
    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = fm.temporaryDirectory.appendingPathComponent("kws-compat-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir {
            try? fm.removeItem(at: tmpDir)
        }
        tmpDir = nil
        try super.tearDownWithError()
    }

    private static let samplePackAppPy = """
    def swift_sources():
        return [HERE / 'Launcher.swift', HERE.parent / 'ios/Sources/LauncherSettings.swift', HERE.parent / 'ios/Sources/LauncherRow.swift', HERE.parent / 'ios/Sources/SaveSyncReport.swift',
                HERE.parent / 'ios/Sources/LauncherHome.swift']
    """

    private static let sampleLauncherHomeSwift = """
    import SwiftUI

    struct AllSettingsDrawer: View {
        @State private var tab = ""
        @State private var testingMic = false
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                List {
                    switch tab {
                    default:
                        Section { EmptyView() }
                        if m.rows(in: current).contains(where: { $0.env == "DM_MIC" || $0.env == "DM_MIC_BOOST" }) {   // MicTester.swift
                            Section {
                                Button("Test Microphone") { testingMic = true }.foregroundStyle(LauncherTheme.paleGold)
                            } footer: { Text("Hum or whistle and see whether the game would hear a note, and which one.") }
                            .listRowBackground(LauncherTheme.row)
                        }
                        Section { EmptyView() }
                    }
                }
                .tint(LauncherTheme.gold)
                .sheet(isPresented: $testingMic) { MicTesterView(m: m) }
            }
        }
    }
    """

    private func makeKWSTree(
        name: String,
        packApp: String = KidWithSwordCompatTests.samplePackAppPy,
        launcherHome: String = KidWithSwordCompatTests.sampleLauncherHomeSwift
    ) throws -> URL {
        let tree = tmpDir.appendingPathComponent(name, isDirectory: true)
        let packURL = tree.appendingPathComponent(KidWithSwordCompat.macPackScriptRelativePath)
        let homeURL = tree.appendingPathComponent(KidWithSwordCompat.launcherHomeRelativePath)
        let buildScript = tree.appendingPathComponent(RepoLayout.buildScript)
        let extractCS = tree.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        for url in [packURL, homeURL, buildScript, extractCS] {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try packApp.write(to: packURL, atomically: true, encoding: .utf8)
        try launcherHome.write(to: homeURL, atomically: true, encoding: .utf8)
        try "#!/usr/bin/env python3\n".write(to: buildScript, atomically: true, encoding: .utf8)
        try "// cs\n".write(to: extractCS, atomically: true, encoding: .utf8)
        return tree
    }

    func testGuardsMicTesterSectionAndSheetAndIsIdempotent() throws {
        let tree = try makeKWSTree(name: "kws-94d1895")
        let homeURL = tree.appendingPathComponent(KidWithSwordCompat.launcherHomeRelativePath)

        XCTAssertTrue(KidWithSwordCompat.ensureMacPackCompatibility(in: tree.path))

        let patched = try String(contentsOf: homeURL, encoding: .utf8)
        let expectedSection = """
                        #if os(iOS)
                        if m.rows(in: current).contains(where: { $0.env == "DM_MIC" || $0.env == "DM_MIC_BOOST" }) {   // MicTester.swift
                            Section {
                                Button("Test Microphone") { testingMic = true }.foregroundStyle(LauncherTheme.paleGold)
                            } footer: { Text("Hum or whistle and see whether the game would hear a note, and which one.") }
                            .listRowBackground(LauncherTheme.row)
                        }
                        #endif
    """
        let expectedSheet = """
                #if os(iOS)
                .sheet(isPresented: $testingMic) { MicTesterView(m: m) }
                #endif
    """
        XCTAssertTrue(patched.contains(expectedSection))
        XCTAssertTrue(patched.contains(expectedSheet))

        // Second pass must be a no-op
        XCTAssertFalse(KidWithSwordCompat.ensureMacPackCompatibility(in: tree.path))
        XCTAssertEqual(try String(contentsOf: homeURL, encoding: .utf8), patched)
    }

    func testSkipsWhenPackAppCompilesMicTesterSwift() throws {
        let packWithMicTester = """
        def swift_sources():
            return [HERE / 'Launcher.swift', HERE.parent / 'ios/Sources/LauncherHome.swift', HERE.parent / 'ios/Sources/MicTester.swift']
        """
        let tree = try makeKWSTree(name: "kws-fixed-pack", packApp: packWithMicTester)
        let homeURL = tree.appendingPathComponent(KidWithSwordCompat.launcherHomeRelativePath)
        let before = try String(contentsOf: homeURL, encoding: .utf8)

        XCTAssertFalse(KidWithSwordCompat.ensureMacPackCompatibility(in: tree.path))
        XCTAssertEqual(try String(contentsOf: homeURL, encoding: .utf8), before)
    }

    func testSkipsWhenAlreadyGuardedUpstream() throws {
        let alreadyGuarded = """
        struct AllSettingsDrawer: View {
            @State private var testingMic = false
            var body: some View {
                VStack {
                    #if os(iOS)
                    if m.rows(in: current).contains(where: { $0.env == "DM_MIC" }) {
                        Button("Test Microphone") { testingMic = true }
                    }
                    #endif
                }
                #if os(iOS)
                .sheet(isPresented: $testingMic) { MicTesterView(m: m) }
                #endif
            }
        }
        """
        let tree = try makeKWSTree(name: "kws-guarded", launcherHome: alreadyGuarded)
        let homeURL = tree.appendingPathComponent(KidWithSwordCompat.launcherHomeRelativePath)

        XCTAssertFalse(KidWithSwordCompat.ensureMacPackCompatibility(in: tree.path))
        XCTAssertEqual(try String(contentsOf: homeURL, encoding: .utf8), alreadyGuarded)
    }

    func testRejectsSymlinkEscapingEngineTree() throws {
        let outside = tmpDir.appendingPathComponent("outside.swift")
        try Self.sampleLauncherHomeSwift.write(to: outside, atomically: true, encoding: .utf8)

        let tree = try makeKWSTree(name: "kws-symlink")
        let homeURL = tree.appendingPathComponent(KidWithSwordCompat.launcherHomeRelativePath)
        try fm.removeItem(at: homeURL)
        try fm.createSymbolicLink(at: homeURL, withDestinationURL: outside)

        XCTAssertFalse(KidWithSwordCompat.ensureMacPackCompatibility(in: tree.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), Self.sampleLauncherHomeSwift)
    }

    func testUpstreamEngineStoreInstallAppliesMacCompatGuardForKidWithSword() throws {
        let stage = tmpDir.appendingPathComponent("zip-stage/kid-with-sword-remake-L", isDirectory: true)
        let tree = try makeKWSTree(name: "zip-src")
        try fm.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tree, to: stage)

        let zipURL = tmpDir.appendingPathComponent("kws.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", tmpDir.appendingPathComponent("zip-stage").path, zipURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let storeRoot = tmpDir.appendingPathComponent("upstreams", isDirectory: true)
        let store = UpstreamEngineStore(root: storeRoot)
        let installed = try store.install(zip: zipURL, kind: .kidWithSword)
        let installedHome = try String(contentsOf: installed.appendingPathComponent(KidWithSwordCompat.launcherHomeRelativePath), encoding: .utf8)
        XCTAssertTrue(installedHome.contains("#if os(iOS)\n            .sheet(isPresented: $testingMic) { MicTesterView(m: m) }\n            #endif"))
    }
}
