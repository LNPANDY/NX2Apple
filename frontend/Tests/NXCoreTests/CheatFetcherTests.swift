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
        XCTAssertEqual(result.receipt.status, "fetched")
        XCTAssertEqual(result.receipt.origin, "fetched")
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

        // Case 1: Existing file without receipt -> preserved_user.
        let r1 = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: transport)
        XCTAssertFalse(r1.wroteFile)
        XCTAssertEqual(r1.receipt.status, "preserved_user")
        XCTAssertEqual(r1.receipt.origin, "user")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), userContent)
        XCTAssertTrue(transport.requests.isEmpty, "must not even hit network when local user file is protected")

        // Case 2: Fresh fetch, then player edits the fetched file -> next fetch preserves player edits.
        try fm.removeItem(at: fileURL)
        try fm.removeItem(at: CheatFetcher.receiptURL(in: temporary))
        let r2 = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: transport)
        XCTAssertTrue(r2.wroteFile)
        XCTAssertEqual(r2.receipt.status, "fetched")

        let editedContent = "[Edited By Player]\n04000000 00180020 00000007\n"
        try Data(editedContent.utf8).write(to: fileURL)
        let r3 = await CheatFetcher.fetch(titleID: titleID, buildID: buildID, into: temporary, transport: transport)
        XCTAssertFalse(r3.wroteFile)
        XCTAssertEqual(r3.receipt.status, "preserved_user")
        XCTAssertEqual(r3.receipt.origin, "user")
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
        XCTAssertEqual(secondFetch.receipt.status, "fetched")
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
}
