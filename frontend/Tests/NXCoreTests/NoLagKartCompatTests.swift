import Foundation
import XCTest
@testable import NXCore

final class NoLagKartCompatTests: XCTestCase {
    private let fm = FileManager.default
    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = fm.temporaryDirectory.appendingPathComponent("nlk-compat-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir {
            try? fm.removeItem(at: tmpDir)
        }
        tmpDir = nil
        try super.tearDownWithError()
    }

    /// Real snippet from `kingbumi31/no-lag-kart` (`dm/host/Makefile` lines 25-30).
    private static let realUpstreamMakefileSnippet = """
    CFLAGS=-O2 -g -Wall -Wno-unused-function -mmacosx-version-min=$(MACOS_MIN)
    # Mario Kart World on this branch: the host is built with the profile of its own runs when the file is there
    ifeq ($(GAME),0400C3F00006E000)
    ifneq ($(wildcard ../../mkw/pgo/dmhost.profdata),)
    CFLAGS+=-fprofile-instr-use=$(abspath ../../mkw/pgo/dmhost.profdata) -Wno-profile-instr-out-of-date -Wno-profile-instr-unprofiled
    endif
    endif
    """

    private func makeNLKTree(
        at root: URL? = nil,
        name: String = "nolagkart",
        makefile: String = NoLagKartCompatTests.realUpstreamMakefileSnippet
    ) throws -> URL {
        let tree = root ?? tmpDir.appendingPathComponent(name, isDirectory: true)
        let makefileURL = tree.appendingPathComponent(NoLagKartCompat.hostMakefileRelativePath)
        let buildScript = tree.appendingPathComponent(RepoLayout.buildScript)
        let extractCS = tree.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        for url in [makefileURL, buildScript, extractCS] {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try makefile.write(to: makefileURL, atomically: true, encoding: .utf8)
        try "#!/usr/bin/env python3\n".write(to: buildScript, atomically: true, encoding: .utf8)
        try "// cs\n".write(to: extractCS, atomically: true, encoding: .utf8)
        return tree
    }

    func testQuotesUpstreamAbspathAndIsIdempotent() throws {
        let tree = try makeNLKTree(name: "nlk-real")
        let makefileURL = tree.appendingPathComponent(NoLagKartCompat.hostMakefileRelativePath)

        XCTAssertTrue(NoLagKartCompat.ensureMacMakefileCompatibility(in: tree.path))

        let patched = try String(contentsOf: makefileURL, encoding: .utf8)
        XCTAssertTrue(
            patched.contains(
                "CFLAGS+=-fprofile-instr-use=\"$(abspath ../../mkw/pgo/dmhost.profdata)\" -Wno-profile-instr-out-of-date -Wno-profile-instr-unprofiled"
            )
        )
        // Must keep Make's wildcard check unquoted so $(wildcard ...) continues to match.
        XCTAssertTrue(patched.contains("ifneq ($(wildcard ../../mkw/pgo/dmhost.profdata),)"))

        // Second pass must be a no-op.
        XCTAssertFalse(NoLagKartCompat.ensureMacMakefileCompatibility(in: tree.path))
        XCTAssertEqual(try String(contentsOf: makefileURL, encoding: .utf8), patched)
    }

    func testQuotesOtherUnquotedProfdataExpansions() throws {
        let customMakefile = """
        CFLAGS+=-fprofile-instr-use=$(CURDIR)/../../mkw/pgo/dmhost.profdata -Wall
        EXTRA_FLAGS=-fprofile-instr-use=${PGO_ROOT}/dmhost.profdata
        """
        let tree = try makeNLKTree(name: "nlk-other-expansions", makefile: customMakefile)
        let makefileURL = tree.appendingPathComponent(NoLagKartCompat.hostMakefileRelativePath)

        XCTAssertTrue(NoLagKartCompat.ensureMacMakefileCompatibility(in: tree.path))
        let patched = try String(contentsOf: makefileURL, encoding: .utf8)
        XCTAssertTrue(patched.contains("CFLAGS+=-fprofile-instr-use=\"$(CURDIR)/../../mkw/pgo/dmhost.profdata\" -Wall"))
        XCTAssertTrue(patched.contains("EXTRA_FLAGS=-fprofile-instr-use=\"${PGO_ROOT}/dmhost.profdata\""))
        XCTAssertFalse(NoLagKartCompat.ensureMacMakefileCompatibility(in: tree.path))
    }

    func testSkipsWhenAlreadyQuotedUpstreamOrInComments() throws {
        let alreadyQuoted = """
        # Example: CFLAGS+=-fprofile-instr-use=$(abspath ../../mkw/pgo/dmhost.profdata)
        ifeq ($(GAME),0400C3F00006E000)
        ifneq ($(wildcard ../../mkw/pgo/dmhost.profdata),)
        CFLAGS+=-fprofile-instr-use="$(abspath ../../mkw/pgo/dmhost.profdata)" -Wno-profile-instr-out-of-date
        CFLAGS+=-fprofile-instr-use='$(abspath ../../mkw/pgo/dmhost.profdata)'
        CFLAGS+="-fprofile-instr-use=$(abspath ../../mkw/pgo/dmhost.profdata)"
        endif
        endif
        """
        let tree = try makeNLKTree(name: "nlk-quoted", makefile: alreadyQuoted)
        let makefileURL = tree.appendingPathComponent(NoLagKartCompat.hostMakefileRelativePath)

        XCTAssertFalse(NoLagKartCompat.ensureMacMakefileCompatibility(in: tree.path))
        XCTAssertEqual(try String(contentsOf: makefileURL, encoding: .utf8), alreadyQuoted)
    }

    func testRejectsSymlinkEscapingEngineTree() throws {
        let outside = tmpDir.appendingPathComponent("outside.Makefile")
        try Self.realUpstreamMakefileSnippet.write(to: outside, atomically: true, encoding: .utf8)

        let tree = try makeNLKTree(name: "nlk-symlink")
        let makefileURL = tree.appendingPathComponent(NoLagKartCompat.hostMakefileRelativePath)
        try fm.removeItem(at: makefileURL)
        try fm.createSymbolicLink(at: makefileURL, withDestinationURL: outside)

        XCTAssertFalse(NoLagKartCompat.ensureMacMakefileCompatibility(in: tree.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), Self.realUpstreamMakefileSnippet)
    }

    func testUpstreamEngineStoreInstallAppliesMacCompatGuardForNoLagKart() throws {
        let stage = tmpDir.appendingPathComponent("zip-stage/no-lag-kart-main", isDirectory: true)
        _ = try makeNLKTree(at: stage)

        let zipURL = tmpDir.appendingPathComponent("nlk.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", tmpDir.appendingPathComponent("zip-stage").path, zipURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let storeRoot = tmpDir.appendingPathComponent("Application Support/NX2Apple/upstreams", isDirectory: true)
        let store = UpstreamEngineStore(root: storeRoot)
        let installed = try store.install(zip: zipURL, kind: .noLagKart)
        let installedMakefile = try String(
            contentsOf: installed.appendingPathComponent(NoLagKartCompat.hostMakefileRelativePath),
            encoding: .utf8
        )
        XCTAssertTrue(
            installedMakefile.contains("CFLAGS+=-fprofile-instr-use=\"$(abspath ../../mkw/pgo/dmhost.profdata)\"")
        )
    }

    func testMakeDryRunInSpacedDirectoryKeepsProfdataFlagSingleArgument() throws {
        let spacedRoot = tmpDir.appendingPathComponent("Application Support/NX2Apple/upstreams/nolagkart", isDirectory: true)
        let profdataURL = spacedRoot.appendingPathComponent("mkw/pgo/dmhost.profdata")
        try fm.createDirectory(at: profdataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("prof".utf8).write(to: profdataURL)

        let makefile = """
        MACOS_MIN=15.0
        CFLAGS=-O2 -mmacosx-version-min=$(MACOS_MIN)
        ifeq ($(GAME),0400C3F00006E000)
        ifneq ($(wildcard ../../mkw/pgo/dmhost.profdata),)
        CFLAGS+=-fprofile-instr-use=$(abspath ../../mkw/pgo/dmhost.profdata) -Wno-profile-instr-out-of-date -Wno-profile-instr-unprofiled
        endif
        endif
        .PHONY: dmhost
        dmhost:
        \tpython3 -c 'import sys; print("\\n".join(sys.argv[1:]))' $(CFLAGS)
        """
        _ = try makeNLKTree(at: spacedRoot, makefile: makefile)
        XCTAssertTrue(NoLagKartCompat.ensureMacMakefileCompatibility(in: spacedRoot.path))

        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        make.currentDirectoryURL = spacedRoot.appendingPathComponent("dm/host", isDirectory: true)
        make.arguments = ["-s", "GAME=0400C3F00006E000", "dmhost"]
        let pipe = Pipe()
        make.standardOutput = pipe
        make.standardError = pipe
        try make.run()
        make.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(make.terminationStatus, 0, "make failed: \(output)")

        let args = output.split(separator: "\n").map(String.init)
        let resolvedCString = realpath(profdataURL.path, nil)
        defer { free(resolvedCString) }
        let expectedPath = resolvedCString.map { String(cString: $0) } ?? profdataURL.resolvingSymlinksInPath().path
        XCTAssertTrue(
            args.contains("-fprofile-instr-use=\(expectedPath)"),
            "Expected single unsplit argument -fprofile-instr-use=\(expectedPath), got: \(args)"
        )
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("Support/") }))
    }
}
