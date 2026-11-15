import XCTest
@testable import NXCore

final class UTF8StreamDecoderTests: XCTestCase {
    private let real = SystemProcessRunner()

    func testSplitThreeAndFourByteScalarsAt4KBAnd16KBBoundariesDecodeIntact() throws {
        // Place a 3-byte check mark (E2 9C 93) across the 4096-byte boundary and a 4-byte CJK Extension B scalar (F0 A0 80 80)
        // across the 16384-byte boundary.
        let head1 = "{\"ev\":\"stage_end\",\"summary\":\""
        let prefix = String(repeating: "x", count: 4096 - Data(head1.utf8).count - 1)
        let event1 = "\(head1)\(prefix)✓ 存档完成 𠀀\"}\n"

        let head2 = "{\"ev\":\"say\",\"msg\":\""
        let pad2 = String(repeating: "y", count: 16384 - Data(event1.utf8).count - Data(head2.utf8).count - 2)
        let event2 = "\(head2)\(pad2)𠀀 ✗ 路径/セーブ…\"}\n"
        let full = event1 + event2
        let bytes = Data(full.utf8)

        // Verify our test fixture genuinely splits multi-byte sequences at 4096 and 16384.
        XCTAssertEqual(bytes[4095], 0xE2)
        XCTAssertEqual(bytes[4096], 0x9C)
        XCTAssertNil(String(data: bytes[..<4096], encoding: .utf8), "4096 boundary must split the 3-byte check mark")
        XCTAssertEqual(bytes[16382], 0xF0)
        XCTAssertEqual(bytes[16384], 0x80)
        XCTAssertNil(String(data: bytes[4096..<16384], encoding: .utf8), "16384 boundary must split the 4-byte scalar")

        for step in [4096, 16384, 257, 7] {
            var decoder = UTF8StreamDecoder()
            var out = ""
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + step, bytes.count)
                out += decoder.decode(bytes[offset..<end])
                offset = end
            }
            out += decoder.finish()
            XCTAssertEqual(out, full, "decoded output must match for chunk size \(step)")
        }

        // Byte-by-byte and 2/3-byte strides across 1-, 2-, 3-, and 4-byte UTF-8 scalars.
        let compact = "ASCII · é · ✓✗… · 存档路径/セーブ · 𠀀𠀁\n"
        let compactBytes = Data(compact.utf8)
        for step in [1, 2, 3, 5] {
            var decoder = UTF8StreamDecoder()
            var out = ""
            var offset = 0
            while offset < compactBytes.count {
                let end = min(offset + step, compactBytes.count)
                out += decoder.decode(compactBytes[offset..<end])
                offset = end
            }
            out += decoder.finish()
            XCTAssertEqual(out, compact, "decoded output must match for stride \(step)")
        }
    }

    func testMalformedBytesBecomeReplacementCharactersWithoutDroppingSurroundingText() {
        var decoder = UTF8StreamDecoder()
        // Invalid standalone 0xFF and overlong 0xC0 0xAF surrounded by valid ASCII and UTF-8.
        let chunk1 = Data("head:".utf8) + Data([0xFF, 0xC0, 0xAF]) + Data(":mid:".utf8) + Data([0xE2, 0x9C])
        let part1 = decoder.decode(chunk1)
        XCTAssertTrue(part1.hasPrefix("head:\u{FFFD}"))
        XCTAssertTrue(part1.hasSuffix(":mid:"))
        // Empty chunk must not flush the held-back [0xE2, 0x9C] prefix prematurely.
        XCTAssertEqual(decoder.decode(Data()), "")
        // Next chunk starts with ASCII instead of 0x93, then ends with an unclosed 2-byte prefix [0xE4, 0xB8].
        let chunk2 = Data("tail".utf8) + Data([0xE4, 0xB8])
        let part2 = decoder.decode(chunk2)
        XCTAssertEqual(part2, "\u{FFFD}tail")
        // EOF flushes the unclosed prefix as a replacement character and is idempotent afterwards.
        XCTAssertEqual(decoder.finish(), "\u{FFFD}")
        XCTAssertEqual(decoder.finish(), "")
    }

    func testProcessRunnerStreamPreservesMultiByteUTF8AndPartialLinesAcross4KBPipeChunksAndEOF() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required") }
        // Write 4095 ASCII bytes + the first byte of "✓" (E2 9C 93), flush and sleep so the pipe reader receives a chunk
        // ending mid-scalar and mid-line, then write the remaining two bytes + CJK + newline + a trailing line with no newline.
        let script = """
        import sys, time
        sys.stdout.buffer.write(b'a' * 4095 + b'\\xe2')
        sys.stdout.buffer.flush()
        time.sleep(0.06)
        sys.stdout.buffer.write(b'\\x9c\\x93 ' + '存档路径\\nfinal-tail-✓'.encode('utf-8'))
        sys.stdout.buffer.flush()
        """
        let lock = NSLock()
        var lines: [String] = []
        let ok = real.stream(ProcessLaunch(["/usr/bin/python3", "-c", script])) { line in
            lock.lock(); lines.append(line); lock.unlock()
        }
        XCTAssertTrue(ok)
        let expectedFirst = String(repeating: "a", count: 4095) + "✓ 存档路径"
        XCTAssertEqual(lines, [expectedFirst, "final-tail-✓"])
    }

    func testProcessRunnerCaptureHandlesLargeBidirectionalStdinWithoutDeadlocking() {
        // 256 KB exceeds the 64 KB macOS kernel pipe buffer by 4x: synchronous stdin write before draining stdout deadlocks.
        let unit = "0123456789abcdef✓存档\n"
        let payload = String(repeating: unit, count: 12_000)
        XCTAssertGreaterThan(payload.utf8.count, 200_000)

        let echoed = real.capture(ProcessLaunch(executable: "/bin/cat", timeout: 5, input: payload))
        XCTAssertTrue(echoed.started)
        XCTAssertFalse(echoed.timedOut, "capture must drain stdout concurrently while writing >128 KB to stdin")
        XCTAssertTrue(echoed.ok)
        XCTAssertEqual(echoed.out, payload)

        // A child that exits immediately without reading stdin must not raise SIGPIPE or NSFileHandleOperationException.
        let ignored = real.capture(ProcessLaunch(executable: "/usr/bin/true", timeout: 5, input: payload))
        XCTAssertTrue(ignored.ok)
    }

    func testFastExitingGroupedProcessesNeverLeaveDeadPIDsInProcessGroups() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("System Python is required") }
        let baseline = ProcessGroups.trackedCount

        // Deterministic race ordering: terminationHandler untracks before run() caller reaches track(_:).
        let exitedProc = Process()
        exitedProc.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exitedProc.run()
        exitedProc.waitUntilExit()
        XCTAssertFalse(exitedProc.isRunning)

        let reg = ProcessGroups.Registration()
        reg.untrack(exitedProc)
        reg.track(exitedProc)
        ProcessGroups.track(exitedProc)
        XCTAssertEqual(ProcessGroups.trackedCount, baseline, "an already-exited or pre-untracked process must never be inserted")

        // Real rapid-exit stress across grouped launches.
        for _ in 0..<15 {
            let done = expectation(description: "grouped-exit")
            _ = try real.start(
                ProcessLaunch(["/usr/bin/true"], groupPython: "/usr/bin/python3"),
                onOutput: { _ in },
                onExit: { _ in done.fulfill() }
            )
            wait(for: [done], timeout: 5)
        }
        XCTAssertEqual(ProcessGroups.trackedCount, baseline)
        XCTAssertFalse(ProcessGroups.buildProcessesAlive)
    }
}
