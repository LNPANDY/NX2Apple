import XCTest
@testable import NXCore

/// #816 "After a crash": how a session ended, from the last lines dm/mac/launcher.c and dm/host/crash.c write to the game's log.
final class GameExitTests: XCTestCase {
    private let start = "fork patches: 0001 0002\nlauncher: Hades (0100000000000001), host /Applications/Hades.app/Contents/MacOS/dmhost\n[dm] front end: started"

    func testANormalQuitIsExitStatusZero() {
        XCTAssertEqual(GameExit.from(logTail: start + "\nlauncher: the host exited with 0\n"), .quit)
    }

    func testACrashANonZeroExitAndASignalStopUnexpectedly() {
        XCTAssertEqual(GameExit.from(logTail: start + "\n[dm] CRASH sig=11 pc=0x1\nlauncher: the host exited with 139"), .stoppedUnexpectedly,
                       "crash.c exits with 128 + the signal")
        XCTAssertEqual(GameExit.from(logTail: start + "\nlauncher: the host exited with 70"), .stoppedUnexpectedly, "the GPU stopped (EX_SOFTWARE)")
        XCTAssertEqual(GameExit.from(logTail: start + "\nlauncher: the host stopped on signal 6"), .stoppedUnexpectedly, "an abort")
        XCTAssertEqual(GameExit.from(logTail: start + "\n[dm] CRASH sig=11"), .stoppedUnexpectedly, "the crash line alone, the launcher's line cut")
    }

    func testASignalSentToEndTheGameIsAQuit() {
        for signal in [1, 2, 9, 15] {
            XCTAssertEqual(GameExit.from(logTail: start + "\nlauncher: the host stopped on signal \(signal)"), .quit, "signal \(signal)")
        }
    }

    func testNothingAboutTheEndIsUnknown() {
        XCTAssertEqual(GameExit.from(logTail: ""), .unknown)
        XCTAssertEqual(GameExit.from(logTail: start), .unknown, "the session's start and nothing after it")
        XCTAssertEqual(GameExit.from(logTail: start + "\nlauncher: the host exited with "), .unknown, "a cut line")
        // the crash of an earlier session before this session's start does not count
        XCTAssertEqual(GameExit.from(logTail: "[dm] CRASH sig=11\n" + start), .unknown)
    }

    func testTheLastEndWins() {
        let two = start + "\nlauncher: the host exited with 139\n" + start + "\nlauncher: the host exited with 0"
        XCTAssertEqual(GameExit.from(logTail: two), .quit)
    }
}
