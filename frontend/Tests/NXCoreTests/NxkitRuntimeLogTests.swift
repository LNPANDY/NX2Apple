import Foundation
import XCTest
@testable import NXCore

final class NxkitRuntimeLogTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "01004D300C5AE000"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxkit-runtime-log-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    private var home: String { temporary.appendingPathComponent("home").path }

    @discardableResult
    private func write(_ url: URL, _ text: String, age: TimeInterval = 0) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func makeIPS(bundleID: String, captureTime: String = "2026-11-22 16:10:55.0000 +0100",
                         signal: String = "SIGABRT", indicator: String = "Abort trap: 6",
                         asiMessage: String = "abort() called", procPath: String = "/tmp/Game.app/Contents/MacOS/nxkit-host") throws -> String {
        let header: [String: Any] = [
            "app_name": "nxkit-host",
            "bundleID": bundleID,
            "timestamp": captureTime,
        ]
        let body: [String: Any] = [
            "captureTime": captureTime,
            "procPath": procPath,
            "bundleInfo": ["CFBundleIdentifier": bundleID],
            "exception": ["type": "EXC_CRASH", "signal": signal, "codes": "0x0, 0x0"],
            "termination": ["namespace": "SIGNAL", "indicator": indicator, "code": 6],
            "asi": ["libsystem_c.dylib": [asiMessage]],
            "faultingThread": 1,
            "usedImages": [
                ["name": "nxkit-host"],
                ["name": "libsystem_kernel.dylib"],
            ],
            "threads": [
                ["name": "main", "frames": []],
                [
                    "name": "guest-0x8f",
                    "frames": [
                        ["imageIndex": 1, "symbol": "__pthread_kill", "symbolLocation": 8, "imageOffset": 38480],
                        ["imageIndex": 0, "symbol": "nxkit_fatal_trap", "symbolLocation": 24, "imageOffset": 123456],
                    ],
                ],
            ],
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        return String(decoding: headerData, as: UTF8.self) + "\n" + String(decoding: bodyData, as: UTF8.self)
    }

    func testReturnsEmptyWhenNoLogsOrCrashesExist() {
        XCTAssertEqual(NxkitRuntimeLog.collect(titleID: titleID, home: home), "")
    }

    func testCollectsLastErrorLogAndFiltersBySince() throws {
        let logURL = URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/nxkit/last-error.log")
        try write(logURL, "nxkit-host: fatal: old error\nnxkit-host: fatal: missing shader cache\n", age: 120)

        let collected = NxkitRuntimeLog.collect(titleID: titleID, home: home)
        XCTAssertTrue(collected.contains("--- last-error.log ---"))
        XCTAssertTrue(collected.contains("nxkit-host: fatal: missing shader cache"))

        let filtered = NxkitRuntimeLog.collect(titleID: titleID, since: Date().addingTimeInterval(-30), home: home)
        XCTAssertEqual(filtered, "", "stale last-error.log from before the build is ignored")
    }

    func testCollectsPerGameHostLogFromLibraryMarkerOrHomeLogs() throws {
        let library = temporary.appendingPathComponent("Library")
        let app = library.appendingPathComponent("Game.app")
        try write(library.appendingPathComponent(NxkitRuntimeLog.libraryMarker), "")
        try write(library.appendingPathComponent("log/\(titleID.lowercased()).log"), "nxkit-host: booting\nnxkit-host: window failed\n", age: 5)
        try write(URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/nxkit/\(titleID).log"), "older home log\n", age: 60)

        let collected = NxkitRuntimeLog.collect(titleID: titleID, appPath: app.path, home: home)
        XCTAssertTrue(collected.contains("--- host log (\(titleID.lowercased()).log) ---"))
        XCTAssertTrue(collected.contains("nxkit-host: window failed"))
        XCTAssertFalse(collected.contains("older home log"))
    }

    func testCollectsMatchingIPSCrashSummaryAndIgnoresOtherGames() throws {
        let diag = URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/DiagnosticReports")
        let otherIPS = try makeIPS(bundleID: "org.nxkit.game.0100ffffffffffff", asiMessage: "wrong game")
        let targetIPS = try makeIPS(bundleID: "org.nxkit.game." + titleID.lowercased(), asiMessage: "guest panic at 0x1000")
        try write(diag.appendingPathComponent("nxkit-host-2026-11-22-160000.ips"), targetIPS, age: 30)
        try write(diag.appendingPathComponent("nxkit-host-2026-11-22-161000.ips"), otherIPS, age: 5)

        let collected = NxkitRuntimeLog.collect(titleID: titleID, home: home)
        XCTAssertTrue(collected.contains("--- crash report (nxkit-host-2026-11-22-160000.ips) ---"))
        XCTAssertTrue(collected.contains("exception: EXC_CRASH (SIGABRT)"))
        XCTAssertTrue(collected.contains("termination: SIGNAL Abort trap: 6 code 6"))
        XCTAssertTrue(collected.contains("asi: libsystem_c.dylib: guest panic at 0x1000"))
        XCTAssertTrue(collected.contains("faultingThread 1 (guest-0x8f):"))
        XCTAssertTrue(collected.contains("1 nxkit-host nxkit_fatal_trap + 24"))
        XCTAssertFalse(collected.contains("wrong game"))
    }

    func testCrashAndLastErrorSurviveURLCapWhenHostLogIsLong() throws {
        let diag = URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/DiagnosticReports")
        try write(diag.appendingPathComponent("nxkit-host-2026-11-22-160000.ips"),
                  try makeIPS(bundleID: "org.nxkit.game." + titleID.lowercased(), asiMessage: "fatal runtime trap"),
                  age: 2)
        try write(URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/nxkit/last-error.log"),
                  "nxkit-host: fatal: unable to initialize Metal device\n",
                  age: 1)
        let noisyHost = (1...120).map { "frame \($0) " + String(repeating: "a", count: 70) }.joined(separator: "\n")
        try write(URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/nxkit/\(titleID).log"), noisyHost, age: 3)

        let collected = NxkitRuntimeLog.collect(titleID: titleID, home: home)
        let report = NxkitFeedback.Report(
            gameName: "Kirby",
            titleID: titleID,
            gameVersion: "1.1.0",
            nxkitVersion: "0.16.6",
            engineBuild: "24dfe3b6b4e7",
            result: .doesNotStart,
            exitCode: nil,
            log: collected,
            macModel: "Mac17,2",
            macOSVersion: "27.2.1"
        )
        let url = NxkitFeedback.issueURL(report, home: home, user: "player")
        XCTAssertLessThanOrEqual(url.absoluteString.count, NxkitFeedback.maxURLLength)

        let items = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        let logField = items[NxkitFeedback.Field.log] ?? ""
        XCTAssertTrue(logField.contains("nxkit-host: fatal: unable to initialize Metal device"))
        XCTAssertTrue(logField.contains("fatal runtime trap"))
    }
}
