import Foundation
import XCTest
@testable import NXCore

final class CheatFetcherTests: XCTestCase {
    private var temporary: URL!
    private let fm = FileManager.default
    private let titleID = "010015100b514000"
    private let buildID = "cd57b23fa4bbad65"

    private struct MockResponse {
        var statusCode: Int
        var data: Data
    }

    private final class MockTransport: CheatFetchTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let handler: @Sendable (URL, TimeInterval, Int) throws -> (Int, Data)
        private(set) var requests: [(url: String, timeout: TimeInterval, maxBytes: Int)] = []

        init(_ handler: @escaping @Sendable (URL, TimeInterval, Int) throws -> (Int, Data)) {
            self.handler = handler
        }

        func fetch(url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> (statusCode: Int, data: Data) {
            lock.lock()
            requests.append((url.absoluteString, timeout, maxBytes))
            lock.unlock()
            return try handler(url, timeout, maxBytes)
        }
    }

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("nx-cheat-fetcher-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: temporary)
    }

    func testFetchesThreeSourcesInOrderMergesMastersFirstAndDeduplicatesWithoutTouchingSwitches() async throws {
        let tidUpper = titleID.uppercased()
        let bidUpper = buildID.uppercased()
        let existingEnabled = temporary.appendingPathComponent("\(bidUpper).enabled")
        try Data("Existing Cheat\n".utf8).write(to: existingEnabled)

        let db1 = """
        {
          "attribution": {"author": "db1"},
          "cd57b23fa4bbad65": {
            "[Infinite HP]": "04000000 00180020 000003E7\\n",
            "{Master First}": "04000000 00000010 00000001"
          }
        }
        """
        let db2 = """
        {
          "CD57B23FA4BBAD650000000000000000": {
            "[Infinite HP]": "04000000 00180020 00000999",
            "[2x Speed]": ["80000040", "04000000 00000800 1E202800", "20000000"],
            "{Master Second}": "{Master Second}\\n04000000 00000014 00000002"
          }
        }
        """
        let db3 = """
        {
          "1111111111111111": {
            "[Other Build]": "04000000 00000001 00000001"
          }
        }
        """

        let transport = MockTransport { url, timeout, maxBytes in
            XCTAssertEqual(timeout, 5.0)
            XCTAssertEqual(maxBytes, 4 * 1024 * 1024)
            let s = url.absoluteString
            if s.contains("/cheats/\(tidUpper).json") { return (200, Data(db1.utf8)) }
            if s.contains("/cheats_gbatemp/\(tidUpper).json") { return (200, Data(db2.utf8)) }
            if s.contains("/cheats_gfx/\(tidUpper).json") { return (200, Data(db3.utf8)) }
            return (404, Data())
        }

        let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)
        let result = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: transport, now: fixedNow)

        XCTAssertTrue(result.wroteFile)
        XCTAssertEqual(result.receipt.schemaVersion, 1)
        XCTAssertEqual(result.receipt.titleID, tidUpper)
        XCTAssertEqual(result.receipt.buildID, bidUpper)
        XCTAssertEqual(result.receipt.status, "found")
        XCTAssertEqual(result.receipt.origin, "fetched")
        XCTAssertEqual(result.onlineLookupStatus, .found)
        XCTAssertEqual(result.onlineSources, ["switch-cheats-db", "cheats_gbatemp"])
        XCTAssertEqual(result.onlineEntryCount, 4)
        XCTAssertNotNil(result.onlineText)
        XCTAssertEqual(result.receipt.sources, ["switch-cheats-db", "cheats_gbatemp"])
        XCTAssertEqual(result.receipt.entryCount, 4)
        XCTAssertEqual(result.receipt.fileName, "\(bidUpper).txt")

        let writtenURL = temporary.appendingPathComponent("\(bidUpper).txt")
        let written = try String(contentsOf: writtenURL, encoding: .utf8)
        XCTAssertEqual(result.receipt.fileSHA256, CheatFetcher.sha256Hex(Data(written.utf8)))

        // Master entries come before regular cheats; duplicate Infinite HP uses db1's value; header is not duplicated.
        let masterFirstIdx = try XCTUnwrap(written.range(of: "{Master First}")?.lowerBound)
        let masterSecondIdx = try XCTUnwrap(written.range(of: "{Master Second}")?.lowerBound)
        let hpIdx = try XCTUnwrap(written.range(of: "[Infinite HP]")?.lowerBound)
        let speedIdx = try XCTUnwrap(written.range(of: "[2x Speed]")?.lowerBound)
        XCTAssertLessThan(masterFirstIdx, hpIdx)
        XCTAssertLessThan(masterSecondIdx, hpIdx)
        XCTAssertLessThan(masterSecondIdx, speedIdx)
        XCTAssertTrue(written.contains("000003E7"))
        XCTAssertFalse(written.contains("00000999"), "first source must win on duplicate entry name")
        XCTAssertFalse(written.contains("{Master Second}\n{Master Second}"), "header already present in body must not duplicate")

        // Never touches existing .enabled switches.
        XCTAssertEqual(try String(contentsOf: existingEnabled, encoding: .utf8), "Existing Cheat\n")

        // Persisted receipt matches returned receipt.
        XCTAssertEqual(CheatFetcher.readReceipt(in: temporary), result.receipt)
        XCTAssertEqual(transport.requests.map(\.url), [
            "https://raw.githubusercontent.com/HamletDuFromage/switch-cheats-db/master/cheats/\(tidUpper).json",
            "https://raw.githubusercontent.com/HamletDuFromage/switch-cheats-db/master/cheats_gbatemp/\(tidUpper).json",
            "https://raw.githubusercontent.com/HamletDuFromage/switch-cheats-db/master/cheats_gfx/\(tidUpper).json",
        ])
    }

    func testPreservesExistingUserFileAndEditedFetchedFile() async throws {
        let bidUpper = buildID.uppercased()
        let fileURL = temporary.appendingPathComponent("\(bidUpper).txt")
        let userContent = "[User Custom]\n04000000 00180020 00000001\n"
        try Data(userContent.utf8).write(to: fileURL)

        let transport = MockTransport { _, _, _ in
            let body = """
            {"\(bidUpper)": {"[Online]": "04000000 00180020 00000002"}}
            """
            return (200, Data(body.utf8))
        }

        // Case 1: Existing user file without receipt -> queries online for preview, preserves local file, returns onlineText.
        let r1 = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: transport)
        XCTAssertFalse(r1.wroteFile)
        XCTAssertEqual(r1.receipt.status, "preserved_user")
        XCTAssertEqual(r1.receipt.origin, "user")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), userContent)
        XCTAssertEqual(transport.requests.count, 3, "must still query all 3 online sources so user can preview and compare")
        XCTAssertEqual(r1.onlineLookupStatus, .found)
        XCTAssertEqual(r1.onlineEntryCount, 1)
        XCTAssertEqual(r1.onlineSources, ["switch-cheats-db"])
        XCTAssertTrue(r1.onlineText?.contains("[Online]") ?? false)

        // Case 1b: Existing user file when online returns 404 or offline -> reports accurate lookup status without modifying local file.
        let notFoundTransport = MockTransport { _, _, _ in (404, Data()) }
        let rNotFound = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: notFoundTransport)
        XCTAssertFalse(rNotFound.wroteFile)
        XCTAssertEqual(rNotFound.receipt.status, "preserved_user")
        XCTAssertEqual(rNotFound.onlineLookupStatus, .notFound)
        XCTAssertNil(rNotFound.onlineText)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), userContent)

        let offlineTransport = MockTransport { _, _, _ in throw URLError(.notConnectedToInternet) }
        let rOffline = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: offlineTransport)
        XCTAssertFalse(rOffline.wroteFile)
        XCTAssertEqual(rOffline.receipt.status, "preserved_user")
        XCTAssertEqual(rOffline.onlineLookupStatus, .offline)
        XCTAssertNil(rOffline.onlineText)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), userContent)

        // Case 2: Fresh fetch, then player edits the fetched file -> next fetch preserves player edits while returning preview candidate.
        try fm.removeItem(at: fileURL)
        try fm.removeItem(at: CheatFetcher.receiptURL(in: temporary))
        let r2 = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: transport)
        XCTAssertTrue(r2.wroteFile)
        XCTAssertEqual(r2.receipt.status, "found")

        let editedContent = "[Edited By Player]\n04000000 00180020 00000007\n"
        try Data(editedContent.utf8).write(to: fileURL)
        let r3 = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: transport)
        XCTAssertFalse(r3.wroteFile)
        XCTAssertEqual(r3.receipt.status, "preserved_user")
        XCTAssertEqual(r3.receipt.origin, "user")
        XCTAssertTrue(r3.onlineText?.contains("[Online]") ?? false)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), editedContent)

        // Case 3: Unmodified fetched file can be updated on subsequent fetch.
        try fm.removeItem(at: fileURL)
        try fm.removeItem(at: CheatFetcher.receiptURL(in: temporary))
        let firstFetch = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: transport)
        XCTAssertTrue(firstFetch.wroteFile)
        let secondTransport = MockTransport { _, _, _ in
            let body = """
            {"\(bidUpper)": {"[Online V2]": "04000000 00180020 00000099"}}
            """
            return (200, Data(body.utf8))
        }
        let secondFetch = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: secondTransport)
        XCTAssertTrue(secondFetch.wroteFile)
        XCTAssertEqual(secondFetch.receipt.status, "found")
        XCTAssertTrue((try String(contentsOf: fileURL, encoding: .utf8)).contains("[Online V2]"))
    }

    func testOfflineAndNotFoundStatusesPreserveFetchedReceiptFingerprint() async throws {
        let offlineTransport = MockTransport { _, _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let offline = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: offlineTransport)
        XCTAssertFalse(offline.wroteFile)
        XCTAssertEqual(offline.receipt.status, "offline")

        let notFoundTransport = MockTransport { _, _, _ in (404, Data()) }
        let notFound = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: notFoundTransport)
        XCTAssertFalse(notFound.wroteFile)
        XCTAssertEqual(notFound.receipt.status, "not_found")

        // When a fetched file already exists, an offline check preserves origin="fetched" and fileSHA256.
        let bidUpper = buildID.uppercased()
        let okTransport = MockTransport { _, _, _ in
            (200, Data("{\"\(bidUpper)\": {\"[HP]\": \"04000000 00180020 00000001\"}}".utf8))
        }
        let fetched = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: okTransport)
        XCTAssertTrue(fetched.wroteFile)

        let offlineAfter = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: offlineTransport)
        XCTAssertFalse(offlineAfter.wroteFile)
        XCTAssertEqual(offlineAfter.receipt.status, "offline")
        XCTAssertEqual(offlineAfter.receipt.origin, "fetched")
        XCTAssertEqual(offlineAfter.receipt.fileSHA256, fetched.receipt.fileSHA256)
    }

    func testDiffSummaryHandlesHeadersTrimmingAndSections() {
        let local = """
        [Player Stats]
        20000000
        [  Infinite HP  ]
        04000000 00180020 000003E7
        [Player Stats End]
        20000001
        [Custom Only Local]
        04000000 00180050 00000001
        """
        let online = """
        {Master Code}
        04000000 00000010 00000001

        [--SectionStart:Combat--]
        00000000 00000000 00000000
        [Infinite HP]
        04000000 00180020 00000999

        [Moon Jump]
        80000202
        04000000 00000400 D503201F
        [--SectionEnd:Combat--]
        00000000 00000000 00000000

        [Max Coins]
        04100000 00004200 000F423F
        """
        let diff = CheatFetcher.diffSummary(localText: local, onlineText: online, rxEnd: 0x100000, buildID: buildID)
        XCTAssertEqual(diff.localCount, 2, "Zing section markers must not be counted as effective cheats")
        XCTAssertEqual(diff.onlineCount, 4, "EdiZon section markers must not be counted as effective cheats")
        XCTAssertEqual(diff.addedCount, 3)
        XCTAssertEqual(diff.sameNameCount, 1)
        XCTAssertEqual(diff.localOnlyCount, 1)
        XCTAssertEqual(diff.entries.map(\.name), ["Master Code", "Infinite HP", "Moon Jump", "Max Coins"])
        XCTAssertEqual(diff.entries.map(\.status), [.added, .sameName, .added, .added])
        XCTAssertEqual(diff.entries[1].section, "Combat")
        XCTAssertEqual(diff.entries[2].capability, .codeNeedsBake)
        XCTAssertEqual(diff.entries[2].triggerCombo, "B + ZR")
        XCTAssertEqual(diff.entries[3].capability, .fixedHeapWarning)
        XCTAssertTrue(diff.entries[2].rawBlock.contains("D503201F"))
    }

    func testMergeMissingEntriesBacksUpPrependsMasterAppendsRegularsAndKeepsSwitches() throws {
        let bidUpper = buildID.uppercased()
        let fileURL = temporary.appendingPathComponent("\(bidUpper).txt")
        let enabledURL = temporary.appendingPathComponent("\(bidUpper).enabled")
        let backupURL = temporary.appendingPathComponent("\(bidUpper).txt.bak")

        let local = "[Infinite HP]\n04000000 00180020 000003E7\n\n[Local Custom]\n04000000 00180040 00000005\n"
        try Data(local.utf8).write(to: fileURL)
        try Data("Infinite HP\n".utf8).write(to: enabledURL)

        let online = """
        {Master}
        04000000 00000010 00000001

        [Infinite HP]
        04000000 00180020 00000999

        [2x Speed]
        04000000 00180060 3F800000
        """

        let fixedNow = Date(timeIntervalSince1970: 1_790_000_123)
        let outcome = try CheatFetcher.mergeMissingEntries(
            localText: local,
            onlineText: online,
            into: temporary,
            buildID: buildID,
            titleID: titleID,
            sources: ["switch-cheats-db"],
            now: fixedNow
        )

        XCTAssertEqual(outcome.addedCount, 2)
        XCTAssertEqual(outcome.totalEntryCount, 4)
        XCTAssertEqual(outcome.backupFileName, "\(bidUpper).txt.bak")
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), local)

        let merged = try String(contentsOf: fileURL, encoding: .utf8)
        let masterPos = try XCTUnwrap(merged.range(of: "{Master}")?.lowerBound)
        let hpPos = try XCTUnwrap(merged.range(of: "[Infinite HP]")?.lowerBound)
        let speedPos = try XCTUnwrap(merged.range(of: "[2x Speed]")?.lowerBound)
        XCTAssertLessThan(masterPos, hpPos, "missing {Master} must be prepended")
        XCTAssertLessThan(hpPos, speedPos, "new regular entries must be appended")
        XCTAssertTrue(merged.contains("000003E7"), "existing local entry body must be kept")
        XCTAssertFalse(merged.contains("00000999"), "same-name online entry must not duplicate or overwrite local")

        // Existing .enabled switches remain untouched; newly added entries remain off.
        XCTAssertEqual(try String(contentsOf: enabledURL, encoding: .utf8), "Infinite HP\n")

        let receipt = try XCTUnwrap(CheatFetcher.readReceipt(in: temporary))
        XCTAssertEqual(receipt.origin, "user")
        XCTAssertEqual(receipt.status, "found")
        XCTAssertEqual(receipt.sources, ["switch-cheats-db"])
        XCTAssertEqual(receipt.entryCount, 4)
        XCTAssertEqual(receipt.fileSHA256, CheatFetcher.sha256Hex(Data(merged.utf8)))
    }

    func testReplaceWithOnlineBacksUpReplacesUpdatesReceiptAndPrunesEnabled() throws {
        let bidUpper = buildID.uppercased()
        let fileURL = temporary.appendingPathComponent("\(bidUpper).txt")
        let enabledURL = temporary.appendingPathComponent("\(bidUpper).enabled")
        let backupURL = temporary.appendingPathComponent("\(bidUpper).txt.bak")

        let local = "[Keep Me]\n04000000 00180020 00000001\n\n[Old Removed]\n04000000 00180030 00000002\n"
        try Data(local.utf8).write(to: fileURL)
        try Data("Old Removed\nKeep Me\n".utf8).write(to: enabledURL)

        let online = "{Master}\n04000000 00000010 00000001\n\n[Keep Me]\n04000000 00180020 000003E7\n\n[New Online]\n04000000 00180090 00000009\n"
        let outcome = try CheatFetcher.replaceWithOnline(
            onlineText: online,
            into: temporary,
            buildID: buildID,
            titleID: titleID,
            sources: ["cheats_gbatemp"]
        )

        XCTAssertEqual(outcome.totalEntryCount, 3)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), local)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), online)

        // Stale key removed; matching key preserved; master & new entries not auto-enabled.
        XCTAssertEqual(try String(contentsOf: enabledURL, encoding: .utf8), "Keep Me\n")

        let receipt = try XCTUnwrap(CheatFetcher.readReceipt(in: temporary))
        XCTAssertEqual(receipt.status, "found")
        XCTAssertEqual(receipt.origin, "fetched")
        XCTAssertEqual(receipt.sources, ["cheats_gbatemp"])
        XCTAssertEqual(receipt.entryCount, 3)
        XCTAssertEqual(receipt.fileSHA256, CheatFetcher.sha256Hex(Data(online.utf8)))
    }

    func testReceiptDecodesCrossPlatformFoundNumericTimestampAndLegacyFetchedISO8601() throws {
        let pythonJSON = """
        {
          "schemaVersion": 1,
          "titleID": "010015100B514000",
          "buildID": "CD57B23FA4BBAD65",
          "status": "found",
          "sources": ["HamletDuFromage/switch-cheats-db"],
          "entryCount": 12,
          "fetchedAt": 1790000000,
          "fileName": "CD57B23FA4BBAD65.txt",
          "fileSHA256": "abcd",
          "origin": "fetched",
          "detail": ""
        }
        """
        let decodedPy = try JSONDecoder().decode(CheatFetchReceipt.self, from: Data(pythonJSON.utf8))
        XCTAssertEqual(decodedPy.statusKind, .fetched)
        XCTAssertEqual(decodedPy.fetchedDate, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(decodedPy.entryCount, 12)

        let legacyMacJSON = """
        {
          "schemaVersion": 1,
          "titleID": "010015100B514000",
          "buildID": "CD57B23FA4BBAD65",
          "status": "fetched",
          "sources": ["switch-cheats-db"],
          "entryCount": 5,
          "fetchedAt": "2026-09-20T14:13:20Z",
          "fileName": "CD57B23FA4BBAD65.txt",
          "fileSHA256": "ef01",
          "origin": "fetched",
          "detail": ""
        }
        """
        let decodedLegacy = try JSONDecoder().decode(CheatFetchReceipt.self, from: Data(legacyMacJSON.utf8))
        XCTAssertEqual(decodedLegacy.statusKind, .fetched)
        XCTAssertNotNil(decodedLegacy.fetchedDate)
        XCTAssertEqual(CheatFetchStatus.fetched.rawValue, "found")
        XCTAssertEqual(CheatFetchStatus(rawValue: "found"), .fetched)
        XCTAssertEqual(CheatFetchStatus(rawValue: "fetched"), .fetched)
    }
}
