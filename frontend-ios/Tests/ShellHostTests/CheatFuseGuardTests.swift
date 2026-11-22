import Foundation
import Testing
@testable import ShellHost

struct CheatFuseGuardTests {
    private let titleID = "010015100B514000"
    private let buildID = "CD57B23FA4BBAD65"

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cheat-fuse-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    @Test func crashTripsOnlyNewlyEnabledCheatsWhenStableBaselineExists() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cheats = root.appendingPathComponent("cheats", isDirectory: true)
        try write("[Stable HP]\n04000000 00000010 00000001\n[Risky Moon Jump]\n04000000 00000020 00000002\n",
                  to: cheats.appendingPathComponent("\(buildID).txt"))
        try write("Stable HP\n", to: cheats.appendingPathComponent("\(buildID).enabled"))

        let fuse = CheatFuseGuard(titleID: titleID, folder: cheats)
        // First run survives 30s and establishes stable baseline.
        let armed1 = fuse.armBeforeLaunch(buildID: buildID, now: Date(timeIntervalSince1970: 100))
        #expect(armed1?.enabled == ["Stable HP"])
        #expect(armed1?.newlyEnabled == ["Stable HP"])
        #expect(fuse.disarmAndRecordStable(now: Date(timeIntervalSince1970: 135)))
        #expect(fuse.readArmed() == nil)
        #expect(fuse.readStable()?.enabled == ["Stable HP"])

        // Second run adds Risky Moon Jump and crashes within 30s (armed receipt stays on disk).
        try write("Stable HP\nRisky Moon Jump\n", to: cheats.appendingPathComponent("\(buildID).enabled"))
        let armed2 = fuse.armBeforeLaunch(buildID: buildID, now: Date(timeIntervalSince1970: 200))
        #expect(armed2?.enabled == ["Stable HP", "Risky Moon Jump"])
        #expect(armed2?.newlyEnabled == ["Risky Moon Jump"])

        // Next start detects leftover armed receipt and disables ONLY Risky Moon Jump.
        let tripped = fuse.recoverIfArmed(now: Date(timeIntervalSince1970: 215))
        #expect(tripped?.disabled == ["Risky Moon Jump"])
        #expect(tripped?.disabledMaster == false)
        #expect(fuse.readArmed() == nil)
        #expect(fuse.readTripped() == tripped)

        let remaining = try String(contentsOf: cheats.appendingPathComponent("\(buildID).enabled"), encoding: .utf8)
        #expect(remaining == "Stable HP\n")
        #expect(fuse.masterOn)
    }

    @Test func crashWithNoNewlyEnabledDisablesAllArmedEntries() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cheats = root.appendingPathComponent("cheats", isDirectory: true)
        try write("[A]\n04000000 00000010 00000001\n[B]\n04000000 00000020 00000002\n",
                  to: cheats.appendingPathComponent("\(buildID).txt"))
        try write("A\nB\n", to: cheats.appendingPathComponent("\(buildID).enabled"))

        let fuse = CheatFuseGuard(titleID: titleID, folder: cheats)
        // Baseline already contains A and B, then a subsequent launch crashes before 30s.
        _ = fuse.armBeforeLaunch(buildID: buildID)
        #expect(fuse.disarmAndRecordStable())

        let armed = fuse.armBeforeLaunch(buildID: buildID)
        #expect(armed?.newlyEnabled == [])
        #expect(armed?.enabled == ["A", "B"])

        let tripped = fuse.recoverIfArmed()
        #expect(tripped?.disabled == ["A", "B"])
        #expect(tripped?.disabledMaster == false)
        let remaining = try String(contentsOf: cheats.appendingPathComponent("\(buildID).enabled"), encoding: .utf8)
        #expect(remaining.isEmpty)
    }

    @Test func crashWithMasterOnlyWritesMasterOffSwitch() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cheats = root.appendingPathComponent("cheats", isDirectory: true)
        try write("{Master Hook}\n04000000 00000010 00000001\n[Optional]\n04000000 00000020 00000002\n",
                  to: cheats.appendingPathComponent("\(buildID).txt"))

        let fuse = CheatFuseGuard(titleID: titleID, folder: cheats)
        let armed = fuse.armBeforeLaunch(buildID: buildID)
        #expect(armed?.hadMasterOnly == true)
        #expect(armed?.enabled == [])

        let tripped = fuse.recoverIfArmed()
        #expect(tripped?.disabledMaster == true)
        #expect(tripped?.disabled == [])
        #expect(!fuse.masterOn)
        #expect(FileManager.default.fileExists(atPath: fuse.masterOffURL.path))
    }

    @Test func masterOffOrNoActiveCheatsNeverArms() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cheats = root.appendingPathComponent("cheats", isDirectory: true)
        try write("[A]\n04000000 00000010 00000001\n", to: cheats.appendingPathComponent("\(buildID).txt"))

        let fuse = CheatFuseGuard(titleID: titleID, folder: cheats)
        #expect(fuse.armBeforeLaunch(buildID: buildID) == nil)
        #expect(fuse.readArmed() == nil)

        try write("A\n", to: cheats.appendingPathComponent("\(buildID).enabled"))
        try write("", to: fuse.masterOffURL)
        #expect(fuse.armBeforeLaunch(buildID: buildID) == nil)
    }

    @Test func sessionGenerationPreventsStaleDisarmFromTouchingNextSession() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cheats1 = root.appendingPathComponent("game1/cheats", isDirectory: true)
        let cheats2 = root.appendingPathComponent("game2/cheats", isDirectory: true)
        try write("[A]\n04000000 00000010 00000001\n", to: cheats1.appendingPathComponent("\(buildID).txt"))
        try write("A\n", to: cheats1.appendingPathComponent("\(buildID).enabled"))
        try write("[B]\n04000000 00000020 00000002\n", to: cheats2.appendingPathComponent("1111111111111111.txt"))
        try write("B\n", to: cheats2.appendingPathComponent("1111111111111111.enabled"))

        let session = CheatFuseSession()
        let res1 = session.beginSession(titleID: titleID, cheatsFolder: cheats1, buildID: buildID, delaySeconds: 0.15)
        #expect(res1.armed != nil)
        // Cleanly exit game 1 after < 0.15 s before its timer fires.
        session.endSessionCleanly(threshold: 30.0)
        #expect(CheatFuseGuard(titleID: titleID, folder: cheats1).readArmed() == nil)
        #expect(CheatFuseGuard(titleID: titleID, folder: cheats1).readStable() == nil)

        // Start game 2 with a long disarm timer; game 1's stale timer must not disarm game 2.
        let res2 = session.beginSession(titleID: "0100000000010000", cheatsFolder: cheats2, buildID: "1111111111111111", delaySeconds: 60.0)
        #expect(res2.armed != nil)
        Thread.sleep(forTimeInterval: 0.25)
        #expect(CheatFuseGuard(titleID: "0100000000010000", folder: cheats2).readArmed() != nil)
        session.abortBeforeRun()
        #expect(CheatFuseGuard(titleID: "0100000000010000", folder: cheats2).readArmed() == nil)
    }

    @Test func buildIDReadsFromFrameworkFixups() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fw = root.appendingPathComponent("DmGame\(titleID).framework", isDirectory: true)
        try write("# PATCH_OFF\t0x100\n# BUILD_ID\tcd57b23fa4bbad65803d9788c01821ee\n",
                  to: fw.appendingPathComponent("dm/main.fixups.tsv"))
        #expect(CheatFuseGuard.buildID(frameworkURL: fw) == buildID)
    }
}
