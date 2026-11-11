import Foundation
import XCTest
@testable import NXCore

/// Unit tests for PR A4 NXCore additions: streaming pip and engine download progress, `.nsz`/`.xcz` 3.5x peak space estimation,
/// cross-volume `shellRoot` checks, `[k/n]` stage parsing with monotonic overall progress, and `extraTable` failure patterns.
final class PreflightAndProgressCoreTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxcore-pra4-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    // MARK: Module 1B - Toolchain pip progress & EngineUpdate byte progress

    func testPipProgressParsesCollectingDownloadingAndInstallingLines() throws {
        var completed = 0
        let total = 4
        let collecting = try XCTUnwrap(Toolchain.parsePipProgress(line: "Collecting pycryptodome>=3.20", completed: &completed, total: total))
        let collectingFraction = try XCTUnwrap(collecting.fraction)
        XCTAssertEqual(completed, 1)
        XCTAssertGreaterThan(collectingFraction, 0.15)
        XCTAssertLessThan(collectingFraction, 0.65)
        XCTAssertEqual(collecting.detail, "Collecting pycryptodome (1/4)")

        _ = Toolchain.parsePipProgress(line: "Collecting zstandard>=0.23", completed: &completed, total: total)
        let downloading = try XCTUnwrap(
            Toolchain.parsePipProgress(line: "Downloading zstandard-0.23.0.whl (620 kB) 50%", completed: &completed, total: total)
        )
        XCTAssertGreaterThan(try XCTUnwrap(downloading.fraction), collectingFraction)
        XCTAssertTrue(downloading.detail.contains("Downloading"))

        let installing = try XCTUnwrap(
            Toolchain.parsePipProgress(
                line: "Installing collected packages: lz4, pycryptodome, zstandard, zbic",
                completed: &completed,
                total: total
            )
        )
        XCTAssertEqual(try XCTUnwrap(installing.fraction), 0.88, accuracy: 0.001)

        let done = try XCTUnwrap(
            Toolchain.parsePipProgress(line: "Successfully installed lz4-4.3.3 zbic-0.2", completed: &completed, total: total)
        )
        XCTAssertEqual(try XCTUnwrap(done.fraction), 1.0, accuracy: 0.001)
        XCTAssertNil(Toolchain.parsePipProgress(line: "Using cached lz4-4.3.3.whl", completed: &completed, total: total))
    }

    func testMakeVenvStreamsMonotonicProgressFromPipOutput() throws {
        let oldVenv = Toolchain.venvDir
        defer { Toolchain.venvDir = oldVenv }

        let venvPath = temporary.appendingPathComponent("venv")
        Toolchain.venvDir = venvPath.path

        let fakeBase = temporary.appendingPathComponent("base-python3")
        let script = """
        #!/bin/sh
        if [ "$1" = "-c" ]
        then
            echo "3.12"
            exit 0
        fi
        if [ "$1" = "-m" ] && [ "$2" = "venv" ]
        then
            mkdir -p "$3/bin"
            cat > "$3/bin/python3" <<'EOF'
        #!/bin/sh
        if [ "$1" = "-c" ]
        then
            echo "3.12"
            exit 0
        fi
        echo "Collecting lz4"
        echo "Downloading lz4-4.3.3.whl 40%"
        echo "Collecting zbic"
        echo "Installing collected packages: lz4, capstone, fonttools, zbic, nsz"
        echo "Successfully installed lz4 capstone fonttools zbic nsz"
        exit 0
        EOF
            chmod +x "$3/bin/python3"
            exit 0
        fi
        exit 0
        """
        try Data(script.utf8).write(to: fakeBase)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBase.path)

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            var items: [(Double, String)] = []
            func append(_ fraction: Double?, _ detail: String) {
                lock.lock()
                if let fraction {
                    items.append((fraction, detail))
                }
                lock.unlock()
            }
        }
        let recorder = Recorder()
        let result = Toolchain.makeVenv(base: fakeBase.path) { fraction, detail in
            recorder.append(fraction, detail)
        }
        XCTAssertTrue(result.ok, result.log)
        let recorded = recorder.items
        XCTAssertGreaterThanOrEqual(recorded.count, 3, "expected streaming progress callbacks from venv creation and pip")
        for index in 1..<recorded.count {
            XCTAssertGreaterThanOrEqual(recorded[index].0, recorded[index - 1].0, "pip progress must not move backwards")
        }
        XCTAssertEqual(recorded.last?.0 ?? 0, 1.0, accuracy: 0.001)
    }

    func testEngineUpdateFormatDownloadProgressHandlesKnownAndUnknownLengths() {
        let known = EngineUpdate.formatDownloadProgress(written: 26_214_400, expected: 52_428_800)
        XCTAssertEqual(try XCTUnwrap(known.fraction), 0.5, accuracy: 0.01)
        XCTAssertTrue(known.text.contains("50%"), known.text)
        XCTAssertTrue(known.text.contains("/"), known.text)

        let unknown = EngineUpdate.formatDownloadProgress(written: 15_728_640, expected: nil)
        XCTAssertNil(unknown.fraction)
        XCTAssertFalse(unknown.text.isEmpty)
        XCTAssertFalse(unknown.text.contains("%"), unknown.text)
        XCTAssertNil(EngineUpdate.formatDownloadProgress(written: 15_728_640, expected: -1).fraction)
    }

    // MARK: Module 2B - Compressed package 3.5x multiplier and volume comparison

    func testEstimatedNeededAppliesPeakMultiplierOnlyToCompressedPackages() throws {
        let nsp = temporary.appendingPathComponent("Base [0100000000010000].nsp")
        let nsz = temporary.appendingPathComponent("Update [0100000000010800].nsz")
        let xcz = temporary.appendingPathComponent("DLC [0100000000011001].XCZ")
        try Data(count: 1_000).write(to: nsp)
        try Data(count: 2_000).write(to: nsz)
        try Data(count: 400).write(to: xcz)

        XCTAssertFalse(BuildSpace.isCompressedPackage(nsp.path))
        XCTAssertTrue(BuildSpace.isCompressedPackage(nsz.path))
        XCTAssertTrue(BuildSpace.isCompressedPackage(xcz.path))

        // 1000 * 1.0 + 2000 * 3.5 + 400 * 3.5 = 1000 + 7000 + 1400 = 9400
        XCTAssertEqual(BuildSpace.estimatedNeeded(for: [nsp.path, nsz.path, xcz.path]), 9_400)
    }

    func testSameVolumeDistinguishesExternalMountFromSystemDiskAndAllowsUnknowns() {
        let lookup: (String) -> String? = { path in
            if path.hasPrefix("/Volumes/ExternalSSD") { return "vol:/Volumes/ExternalSSD" }
            if path.hasPrefix("/Users/") { return "vol:/" }
            return nil
        }
        XCTAssertFalse(
            BuildSpace.sameVolume("/Volumes/ExternalSSD/Out", "/Users/player/Library/Application Support/NX2Apple/shell", volumeID: lookup)
        )
        XCTAssertTrue(
            BuildSpace.sameVolume("/Users/player/Games", "/Users/player/Library/Application Support/NX2Apple/shell", volumeID: lookup)
        )
        XCTAssertTrue(
            BuildSpace.sameVolume("/Network/UnknownShare", "/Users/player/Library/Application Support/NX2Apple/shell", volumeID: lookup),
            "unknown volume identifiers must not false-block a build"
        )
    }

    // MARK: Module 3A - [k/n] stage total parsing and monotonic overall progress

    func testParseStageWithTotalAndMonotonicOverallFraction() throws {
        let first = try XCTUnwrap(BuildProgress.parseStageWithTotal("[12:00:01] [1/8] extract v0 …"))
        XCTAssertEqual(first.k, 1)
        XCTAssertEqual(first.n, 8)

        let doneFirst = try XCTUnwrap(BuildProgress.parseStageWithTotal("[12:00:10] ✓ [1/8] extract v0 (0:09)"))
        XCTAssertEqual(doneFirst.k, 1)
        XCTAssertEqual(doneFirst.n, 8)
        XCTAssertEqual(doneFirst.state, .done)

        var stages: [Stage] = [Stage(id: 1, name: "extract", state: .running, percent: 80)]
        let f1 = try XCTUnwrap(BuildProgress.overallFraction(stages: stages, totalStages: 8, floor: 0))
        XCTAssertEqual(f1, 0.8 / 8.0, accuracy: 0.001)

        // Stage 1 completes (100%) and Stage 2 starts with nil percent -> overall is 1/8 = 0.125 (>= 0.10)
        stages = [
            Stage(id: 1, name: "extract", state: .done, percent: 100),
            Stage(id: 2, name: "shader split", state: .running, percent: nil),
        ]
        let f2 = try XCTUnwrap(BuildProgress.overallFraction(stages: stages, totalStages: 8, floor: f1))
        XCTAssertGreaterThan(f2, f1)
        XCTAssertEqual(f2, 1.0 / 8.0, accuracy: 0.001)

        // Even if a stage temporarily reports a lower percentage than a previous floor, `floor` keeps progress monotonic
        let fFloor = try XCTUnwrap(BuildProgress.overallFraction(stages: stages, totalStages: 8, floor: 0.42))
        XCTAssertEqual(fFloor, 0.42, accuracy: 0.0001)

        // Post-script stages (id >= 1000, such as Xcode build or device install) advance smoothly without exceeding 1.0
        for index in 1...8 {
            if index > 2 {
                stages.append(Stage(id: index, name: "s\(index)", state: .done, percent: 100))
            } else {
                stages[index - 1].state = .done
                stages[index - 1].percent = 100
            }
        }
        stages.append(Stage(id: 1001, name: "Xcode build", state: .running, percent: 50))
        let fPost = try XCTUnwrap(BuildProgress.overallFraction(stages: stages, totalStages: 8, floor: f2))
        XCTAssertEqual(fPost, 0.95 + 0.5 * 0.045, accuracy: 0.001)
    }

    // MARK: Module 4A - Extra failure classifier patterns and engine alignment

    func testExtraFailurePatternsMatchRealEngineAndXcodeMessages() throws {
        let metalLogs = [
            "[RED] the Metal compiler does not run (xcrun metal): error: cannot execute tool 'metal' due to missing Metal Toolchain",
            "[RED] pso_offline: metal-tt is not available — install the Metal Toolchain",
            "metal_macosx: lock Apple metal version 32023.921 / actual missing — run: xcodebuild -downloadComponent MetalToolchain",
        ]
        for log in metalLogs {
            XCTAssertEqual(BuildFailureClassifier.classify(log).kind, .metalToolchain, log)
        }

        let updateLog = "[RED] no NSP for update v131072 (the game profile needs these versions: v0, v131072)"
        let updateFailure = BuildFailureClassifier.classify(updateLog)
        XCTAssertEqual(updateFailure.kind, .updateMismatch)
        XCTAssertEqual(updateFailure.detail, "v0, v131072")

        let splitMismatch = "[RED] Either these game files are not the versions the profile registers, or shader_split.py now reads them differently."
        XCTAssertEqual(BuildFailureClassifier.classify(splitMismatch).kind, .updateMismatch)

        let provisionalMismatch = "[RED] not the builds provisional game profile 01007EF00011E000 registers: expected abc, got def"
        XCTAssertEqual(BuildFailureClassifier.classify(provisionalMismatch).kind, .updateMismatch)

        let freeAppIDLimit = "error: Your development team has reached the maximum number of provisioning profiles. You can create up to 10 App IDs every 7 days."
        XCTAssertEqual(BuildFailureClassifier.classify(freeAppIDLimit).kind, .appIDLimit)
        XCTAssertEqual(BuildFailureClassifier.classifyInstall(.sign, error: freeAppIDLimit, teamListed: true)?.kind, .appIDLimit)

        let profileCountLimit = "error: Your development team has reached the maximum number of provisioning profiles."
        XCTAssertEqual(BuildFailureClassifier.classify(profileCountLimit).kind, .freeAccountLimit)

        let threeAppLimit = "ERROR: This device has reached the maximum number of installed apps using a free developer profile."
        XCTAssertEqual(BuildFailureClassifier.classifyInstall(.install, error: threeAppLimit, teamListed: true)?.kind, .freeAccountLimit)

        // Verify engine source alignment so an upstream wording change is caught immediately
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildScript = repoRoot.appendingPathComponent("engine/scripts/build_ipa_from_nsp.py")
        let psoScript = repoRoot.appendingPathComponent("engine/dm/gfx/tools/pso_offline.py")
        if FileManager.default.fileExists(atPath: buildScript.path) {
            let scriptSource = try String(contentsOf: buildScript, encoding: .utf8)
            XCTAssertTrue(scriptSource.contains("the Metal compiler does not run"))
            XCTAssertTrue(scriptSource.contains("the game profile needs these versions:"))
            XCTAssertTrue(scriptSource.contains("Either these game files are not the versions the profile registers"))
            XCTAssertTrue(scriptSource.contains("provisional game profile"))
        }
        if FileManager.default.fileExists(atPath: psoScript.path) {
            let psoSource = try String(contentsOf: psoScript, encoding: .utf8)
            XCTAssertTrue(psoSource.contains("pso_offline: metal-tt is not available"))
        }
    }
}
