import XCTest
@testable import ShellUI

/// The decision behind #638: a button press that no shell input caused, right after a controller button and with no
/// finger since, is iPadOS's echo of that button and is not acted on. The press itself needs a device; this does not.
final class SystemEchoWindowTests: XCTestCase {
    func testNoControllerButtonNoEcho() {
        XCTAssertFalse(SystemEchoWindow().isEcho(at: 100))
        var w = SystemEchoWindow()
        w.touch(at: 99)
        XCTAssertFalse(w.isEcho(at: 100))
    }
    func testInsideTheWindowIsTheEcho() {
        var w = SystemEchoWindow()
        w.buttonDown(at: 99.9)
        w.buttonUp(at: 100)  // a quick press, up at 100
        XCTAssertTrue(w.isEcho(at: 100))
        XCTAssertTrue(w.isEcho(at: 100.025), "the echo comes about 25 ms after A comes up")
        XCTAssertTrue(w.isEcho(at: 100.999))
    }
    func testAfterTheWindowIsNot() {
        var w = SystemEchoWindow()
        w.buttonDown(at: 99.9)
        w.buttonUp(at: 100)  // a quick press, up at 100
        XCTAssertFalse(w.isEcho(at: 101))
        XCTAssertFalse(w.isEcho(at: 160))
    }
    func testATouchAfterTheButtonEndsTheWindow() {
        var w = SystemEchoWindow()
        w.buttonDown(at: 99.9)
        w.buttonUp(at: 100)  // a quick press, up at 100
        w.touch(at: 100.2)
        XCTAssertFalse(w.isEcho(at: 100.3), "a tap right after a controller button acts at once")
        w.touch(at: 100)
        XCTAssertFalse(w.isEcho(at: 100.3), "a finger at the same moment counts as after")
    }
    func testATouchBeforeTheButtonDoesNot() {
        var w = SystemEchoWindow()
        w.touch(at: 99.5)
        w.buttonDown(at: 99.9)
        w.buttonUp(at: 100)  // a quick press, up at 100
        XCTAssertTrue(w.isEcho(at: 100.1))
    }
    func testAClockThatWentBackIsNeverTheEcho() {
        var w = SystemEchoWindow()
        w.buttonDown(at: 99.9)
        w.buttonUp(at: 100)  // a quick press, up at 100
        XCTAssertFalse(w.isEcho(at: 99.9))
        XCTAssertFalse(w.isEcho(at: 0))
    }
    @MainActor func testNoEchoWhereThePlatformSendsNone() {
        let gate = InputGate(clock: { 10 }, echoes: false)
        gate.controller(.activate)
        XCTAssertFalse(gate.isSystemEcho, "a Mac click right after a controller button acts")
    }
    func testAButtonHeldLongerThanTheWindow() {
        var w = SystemEchoWindow()
        w.buttonDown(at: 100)
        XCTAssertTrue(w.isEcho(at: 101.5), "held 1.5 s, the shell not yet told of A coming up: still the echo")
        w.buttonUp(at: 101.5)
        XCTAssertTrue(w.isEcho(at: 101.525), "the echo after A comes up is caught")
        XCTAssertFalse(w.isEcho(at: 102.5))
    }
    func testATouchWhileAButtonIsHeldActs() {
        var w = SystemEchoWindow()
        w.buttonDown(at: 100)
        w.touch(at: 101)
        XCTAssertFalse(w.isEcho(at: 101.1))
    }
    func testAButtonWhoseComingUpWasLostStopsCounting() {
        var w = SystemEchoWindow()
        w.buttonDown(at: 100)
        XCTAssertTrue(w.isEcho(at: 129))
        XCTAssertFalse(w.isEcho(at: 130))
    }
    func testTwoButtonsHeldCountUntilBothComeUp() {
        var w = SystemEchoWindow()
        w.buttonDown(at: 100)
        w.buttonDown(at: 100.1)
        w.buttonUp(at: 100.2)
        XCTAssertTrue(w.isEcho(at: 105), "one is still held")
        w.buttonUp(at: 105)
        w.buttonUp(at: 105)  // an extra coming up does not go below none
        XCTAssertEqual(w.held, 0)
        XCTAssertFalse(w.isEcho(at: 106.1))
    }
    func testANewButtonAfterATouchOpensTheWindowAgain() {
        var w = SystemEchoWindow()
        w.buttonDown(at: 100)
        w.buttonUp(at: 100.1)
        w.touch(at: 100.2)
        w.buttonDown(at: 100.5)
        XCTAssertTrue(w.isEcho(at: 100.6))
    }

    @MainActor func testTheGateUsesItsClockAndNeverMarksItsOwnInput() {
        var now: TimeInterval = 10
        let gate = InputGate(clock: { now }, echoes: true)
        XCTAssertFalse(gate.isSystemEcho)
        gate.controller(.activate)
        now = 12
        XCTAssertTrue(gate.isSystemEcho, "A still held")
        gate.controllerUp(.activate)
        now = 12.5
        XCTAssertTrue(gate.isSystemEcho)
        gate.handling = true
        XCTAssertFalse(gate.isSystemEcho, "the shell's own handling of a press is not the echo")
        gate.handling = false
        gate.touch()
        XCTAssertFalse(gate.isSystemEcho)
        now = 13
        gate.controller(.right)
        gate.controller(.right)
        XCTAssertFalse(gate.isSystemEcho, "a direction, held and repeating, does not end a tap that began before it")
        gate.controllerUp(.right)
        XCTAssertFalse(gate.isSystemEcho)
    }
}

/// Which focus targets the D-pad reaches: those of the dialog or panel on top, else only the library's.
final class FocusLayerTests: XCTestCase {
    func testTheTopLayerOwnsTheDPad() {
        XCTAssertTrue(FocusLayer.isLive("set.back", under: .settings))
        XCTAssertFalse(FocusLayer.isLive("lib.play", under: .settings))
        XCTAssertFalse(FocusLayer.isLive("set.back", under: .padMapping))
        XCTAssertTrue(FocusLayer.isLive("map.close", under: .padMapping))
        XCTAssertTrue(FocusLayer.isLive("lib.play", under: nil))
        XCTAssertTrue(FocusLayer.isLive("lib.tile.x", under: nil))
        for layer in FocusLayer.allCases {
            XCTAssertFalse(FocusLayer.isLive(layer.prefix + "close", under: nil), "\(layer) closed is not reached")
        }
    }
    func testTheLibraryUnderALayerTakesOnlyTheShellsPresses() {
        XCTAssertTrue(FocusLayer.libraryTakesPress(fromShell: false, under: nil), "a tap on the library")
        XCTAssertTrue(FocusLayer.libraryTakesPress(fromShell: true, under: .settings), "A on a focused cover with the pane sliding in")
        for layer in FocusLayer.allCases {
            XCTAssertFalse(FocusLayer.libraryTakesPress(fromShell: false, under: layer), "Play behind \(layer) pressed by the system")
        }
    }
    func testPrefixesDoNotOverlap() {
        let all = FocusLayer.allCases.map(\.prefix) + [FocusLayer.libraryPrefix]
        XCTAssertEqual(Set(all).count, all.count)
        for a in all { for b in all where a != b { XCTAssertFalse(a.hasPrefix(b), "\(a) starts with \(b)") } }
    }

    /// Every focus target id written in ShellUI starts with exactly one prefix: a target with none would be reached from
    /// the library under every panel, and one with a prefix of the wrong layer could never be reached.
    func testEveryTargetIDInTheSourcesHasExactlyOnePrefix() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ShellUI")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        // The literal at the start of a target id or a target prefix, as the views pass them.
        let pattern = try Regex(#"(?:shellTarget\(|target: |targetID: |targetPrefix: |targetPrefix = )"([^"\\]*)"#)
        let prefixes = FocusLayer.allCases.map(\.prefix) + [FocusLayer.libraryPrefix]
        var seen = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: pattern) {
                guard let literal = match.output[1].substring.map(String.init), !literal.isEmpty else { continue }
                seen += 1
                let count = prefixes.filter { literal.hasPrefix($0) }.count
                XCTAssertEqual(count, 1, "\(file.lastPathComponent): \"\(literal)\" has \(count) known prefixes")
            }
        }
        XCTAssertGreaterThan(seen, 40, "the pattern still finds the target ids")
    }
}
