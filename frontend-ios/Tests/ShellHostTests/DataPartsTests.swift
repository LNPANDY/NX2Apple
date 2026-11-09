import Foundation
import Testing
import ShellUI
@testable import ShellHost

/// #899: the Mac launcher sends a file larger than one part as `<file>.nxpart.<index>.<count>`, and the app joins a complete set.
@MainActor @Suite struct DataPartsTests {
    private let fm = FileManager.default
    private let size: Int64 = 4

    private func folder(_ box: Sandbox) throws -> URL {
        let dir = box.appData.appendingPathComponent("0100535012974000", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// The parts of `text` as the launcher cuts them, `size` bytes each but the last.
    private func send(_ text: String, as file: String, in dir: URL, only: [Int]? = nil) throws {
        let bytes = Array(text.utf8)
        let count = (bytes.count + Int(size) - 1) / Int(size)
        for index in only ?? Array(0..<count) {
            let part = bytes[(index * Int(size))..<min(bytes.count, (index + 1) * Int(size))]
            let name = file + ".nxpart." + String(format: "%04d", index) + "." + String(format: "%04d", count)
            let url = dir.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(part).write(to: url)
        }
    }
    private func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
    private func leftovers(_ dir: URL) -> [String] {
        ((fm.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? []).filter { $0.contains(".nxpart.") || $0.hasSuffix(".nxjoin") }
    }

    @Test func partNamesAreParsed() {
        #expect(DataParts.partSize == 512 << 20, "the same value as ShellDataParts.partSize in the launcher")
        #expect(DataParts.parse("romfs.img.nxpart.0003.0009") == .init(file: "romfs.img", index: 3, count: 9))
        #expect(DataParts.parse("romfs.img") == nil)
        #expect(DataParts.parse("romfs.img.nxpart.0009.0009") == nil)
        #expect(DataParts.parse("romfs.img.nxpart.x.0009") == nil)
        #expect(DataParts.parse(".nxpart.0000.0001") == nil)
    }

    @Test func aCompleteSetBecomesTheFileAndTheOldFileIsReplaced() throws {
        let box = try Sandbox()
        let dir = try folder(box)
        try box.write("old", to: dir.appendingPathComponent("romfs.img"))
        try send("0123456789", as: "romfs.img", in: dir)
        try send("abcdefgh", as: "aoc/1.img", in: dir)
        let joined = DataParts.joinAll(appDataRoot: box.appData, partSize: size)
        #expect(Set(joined.map(\.lastPathComponent)) == ["romfs.img", "1.img"])
        #expect(text(dir.appendingPathComponent("romfs.img")) == "0123456789")
        #expect(text(dir.appendingPathComponent("aoc/1.img")) == "abcdefgh")
        #expect(leftovers(dir).isEmpty)
        #expect(DataParts.joinAll(appDataRoot: box.appData, partSize: size).isEmpty, "nothing left to join")
    }

    @Test func anIncompleteSetWaitsForTheRest() throws {
        let box = try Sandbox()
        let dir = try folder(box)
        try send("0123456789", as: "romfs.img", in: dir, only: [0, 2])
        #expect(DataParts.joinAll(appDataRoot: box.appData, partSize: size).isEmpty)
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("romfs.img").path))
        #expect(leftovers(dir).count == 2, "the parts stay for the one still on its way")
        try send("0123456789", as: "romfs.img", in: dir, only: [1])
        #expect(DataParts.joinAll(appDataRoot: box.appData, partSize: size).count == 1)
        #expect(text(dir.appendingPathComponent("romfs.img")) == "0123456789")
    }

    @Test func aPartOfTheWrongSizeIsNotJoined() throws {
        let box = try Sandbox()
        let dir = try folder(box)
        try send("0123456789", as: "romfs.img", in: dir)
        try Data("012".utf8).write(to: dir.appendingPathComponent("romfs.img.nxpart.0000.0003"))   // cut off
        #expect(DataParts.joinAll(appDataRoot: box.appData, partSize: size).isEmpty)
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("romfs.img").path))
    }

    @Test func aJoinThatStoppedGoesOnAndOneThatDoesNotFitWaits() throws {
        let box = try Sandbox()
        let dir = try folder(box)
        // stopped while appending the second part: the first is in, the second partly, and only the first part was removed
        try send("0123456789", as: "romfs.img", in: dir, only: [1, 2])
        try Data("012345".utf8).write(to: dir.appendingPathComponent("romfs.img.nxjoin"))
        #expect(DataParts.joinAll(appDataRoot: box.appData, partSize: size).count == 1)
        #expect(text(dir.appendingPathComponent("romfs.img")) == "0123456789")
        #expect(leftovers(dir).isEmpty)

        // a join shorter than the parts before the first one still there cannot go on: it goes, the parts wait to be sent again
        try fm.removeItem(at: dir.appendingPathComponent("romfs.img"))
        try send("0123456789", as: "romfs.img", in: dir, only: [2])
        try Data("01".utf8).write(to: dir.appendingPathComponent("romfs.img.nxjoin"))
        #expect(DataParts.joinAll(appDataRoot: box.appData, partSize: size).isEmpty)
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("romfs.img.nxjoin").path))
        try send("0123456789", as: "romfs.img", in: dir, only: [0, 1])
        #expect(DataParts.joinAll(appDataRoot: box.appData, partSize: size).count == 1)
        #expect(text(dir.appendingPathComponent("romfs.img")) == "0123456789")
    }

    @Test func theAppSaysItJoinsParts() throws {
        let box = try Sandbox()
        let documents = box.appData.deletingLastPathComponent()
        DataParts.writeFeatures(documents: documents)
        #expect(text(documents.appendingPathComponent("shell-features.txt")) == "data-parts 1\n")
    }

    /// At its start the app joins what the launcher sent and reads the library again: the game needs no data any more.
    @Test func theModelJoinsAtItsStartAndTheGameBecomesPlayable() async throws {
        let box = try Sandbox()
        let dir = box.appData.appendingPathComponent(Fixtures.orbit, isDirectory: true)
        try box.write("image", to: dir.appendingPathComponent("romfs.img.nxpart.0000.0001"))   // one part, shorter than a part
        let model = ShellHostModel(config: box.config(), shellSettings: ShellSettingsStore(defaults: UserDefaults(suiteName: "t-shell-\(UUID().uuidString)")!))
        func state() -> GameState? { model.details.first { $0.id == Fixtures.orbit }?.game.state }
        for _ in 0..<500 where state() != .playable { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(state() == .playable)
        #expect(text(dir.appendingPathComponent("romfs.img")) == "image")
        #expect(text(box.appData.deletingLastPathComponent().appendingPathComponent("shell-features.txt")) == "data-parts 1\n")
    }
}
