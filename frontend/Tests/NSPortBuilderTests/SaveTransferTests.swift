import XCTest
@testable import NSPortBuilder

/// Issue #66: the save copied between the Mac and a device. devicectl is a stand-in that serves a folder as the app's data
/// container, so no test reaches a device, and the Mac side is a temporary folder, never the real Application Support.
final class SaveTransferTests: XCTestCase {
    private var temporary: URL!
    private let titleID = "0100535012974000"
    private let fm = FileManager.default

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("nxnative-saves-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: temporary) }

    /// A device's app data container as a folder. `nested` copies a folder into the destination instead of as it, the other
    /// reading of devicectl's --destination; `failCopyFrom` makes every copy from the device fail.
    final class FakeDevice {
        let container: URL
        var reachable = true, nested = false, failCopyFrom = false
        var apps: [(bundle: String, name: String)] = []   // what `device info apps` lists
        var hang: DispatchSemaphore?                      // a command waits here first: a device that never answers
        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
        private var recorded: [[String]] = []
        private let lock = NSLock()
        func clearCalls() { lock.lock(); recorded = []; lock.unlock() }
        init(_ container: URL) { self.container = container }

        func value(_ flag: String, _ args: [String]) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }

        var control: DeviceControl {
            DeviceControl { [self] args in
                lock.lock(); recorded.append(args); lock.unlock()
                if let hang { hang.wait() }
                guard reachable else { return (false, "ERROR: The device is not connected. (com.apple.dt.CoreDeviceError error 4)") }
                let fm = FileManager.default
                switch Array(args.prefix(3)) {
                case ["device", "info", "apps"]:
                    let list = apps.map { ["bundleIdentifier": $0.bundle, "name": $0.name, "version": "1.0"] }
                    let json = try! JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["apps": list]])
                    try! json.write(to: URL(fileURLWithPath: value("--json-output", args)!))
                    return (true, "")
                case ["device", "info", "files"]:
                    let dir = container.appendingPathComponent(value("--subdirectory", args)!)
                    guard fm.fileExists(atPath: dir.path) else { return (false, "ERROR: The file couldn't be opened because there is no such file.") }
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    var files: [[String: Any]] = []
                    for case let url as URL in fm.enumerator(at: dir, includingPropertiesForKeys: nil)! {
                        let v = try! url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                        files.append(["name": url.lastPathComponent, "fileType": v.isDirectory! ? "directory" : "file",
                                      "modificationDate": iso.string(from: v.contentModificationDate!)])
                    }
                    let json = try! JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["files": files]])
                    try! json.write(to: URL(fileURLWithPath: value("--json-output", args)!))
                    return (true, "")
                case ["device", "copy", "from"]:
                    let source = container.appendingPathComponent(value("--source", args)!)
                    var destination = URL(fileURLWithPath: value("--destination", args)!)
                    guard !failCopyFrom, fm.fileExists(atPath: source.path) else { return (false, "ERROR: copy failed") }
                    if nested {
                        try! fm.createDirectory(at: destination, withIntermediateDirectories: true)
                        destination.appendPathComponent(source.lastPathComponent)
                    }
                    try! fm.copyItem(at: source, to: destination)
                    return (true, "")
                case ["device", "copy", "to"]:
                    let destination = container.appendingPathComponent(value("--destination", args)!)
                    // What a real device does (#250): the flag deletes everything in the destination's parent, siblings included
                    if value("--remove-existing-content", args) == "true" {
                        let parent = destination.deletingLastPathComponent()
                        for entry in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] { try? fm.removeItem(at: parent.appendingPathComponent(entry)) }
                    }
                    // Without it the directory is merged into the destination, files overwritten, nothing else touched
                    try! fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    let source = URL(fileURLWithPath: value("--source", args)!)
                    for entry in try! fm.contentsOfDirectory(atPath: source.path) {
                        let target = destination.appendingPathComponent(entry)
                        try? fm.removeItem(at: target)
                        try! fm.copyItem(at: source.appendingPathComponent(entry), to: target)
                    }
                    return (true, "")
                default:
                    return (false, "unexpected")
                }
            }
        }
    }

    private func write(_ text: String, _ url: URL, date: Date) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    private func setUp(device: FakeDevice) -> SaveTransfer {
        let mac = SaveTransfer.legacyMacSave(titleID: titleID, support: temporary.appendingPathComponent("Application Support"))
        var t = SaveTransfer(titleID: titleID, macSave: mac, device: "00008150-AAAA", bundle: "com.example.game", devicectl: device.control)
        t.scratch = temporary
        t.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        return t
    }

    /// The library folder layout: <folder>/<id>.app beside <folder>/.nx2apple-library keeps its save in <folder>/save/<id>
    /// (launcher.c), and reads the ~/Library save only until it has brought it across. A bundle anywhere else keeps ~/Library.
    func testTheMacSaveFollowsTheAppWhenItsFolderHoldsTheLibraryMarker() throws {
        let support = temporary.appendingPathComponent("Application Support")
        let library = temporary.appendingPathComponent("Games")
        let app = library.appendingPathComponent("\(titleID).app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertNil(SaveTransfer.macSave(titleID: titleID, appPath: app.path, support: support).legacy, "no marker beside it: ~/Library")
        try fm.createDirectory(at: library.appendingPathComponent("games"), withIntermediateDirectories: true)
        XCTAssertNil(SaveTransfer.macSave(titleID: titleID, appPath: app.path, support: support).legacy, "a games/ folder alone is not the layout")
        try Data().write(to: library.appendingPathComponent(".nx2apple-library"))
        let paths = SaveTransfer.macSave(titleID: titleID, appPath: app.path, support: support)
        XCTAssertEqual(paths.save.path, library.path + "/save/" + titleID)
        XCTAssertEqual(SaveTransfer.macPath("save_device", save: paths.save).path, library.path + "/save/" + titleID + "_device")

        var t = SaveTransfer(titleID: titleID, macSave: paths.save, legacySave: paths.legacy, device: "00008150-AAAA", bundle: "com.example.game",
                             devicectl: FakeDevice(temporary.appendingPathComponent("container")).control)
        t.scratch = temporary
        try write("old", SaveTransfer.legacyMacSave(titleID: titleID, support: support).appendingPathComponent("data.bin"), date: older)
        XCTAssertEqual(t.readMac(), SaveTransfer.Contents(folders: ["save"], newest: older), "the ~/Library save, until the app copies it")
        try write("new", paths.save.appendingPathComponent("data.bin"), date: newer)
        XCTAssertEqual(t.readMac(), SaveTransfer.Contents(folders: ["save"], newest: newer), "then the one beside the app")
        XCTAssertEqual(t.backups.path, library.path + "/save/" + titleID + "-backups")
    }

    /// A library folder in a temporary place: the app, the marker, and the Application Support folder the default save lives in.
    private func layout(marker: Bool) throws -> (library: URL, app: URL, support: URL, transfer: SaveTransfer) {
        let support = temporary.appendingPathComponent("Application Support")
        let library = temporary.appendingPathComponent("Library folder")
        let app = library.appendingPathComponent("\(titleID).app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        if marker { try Data().write(to: library.appendingPathComponent(".nx2apple-library")) }
        let paths = SaveTransfer.macSave(titleID: titleID, appPath: app.path, support: support)
        var t = SaveTransfer(titleID: titleID, macSave: paths.save, legacySave: paths.legacy, device: "00008150-AAAA", bundle: "com.example.game",
                             devicectl: FakeDevice(temporary.appendingPathComponent("container")).control)
        t.scratch = temporary
        return (library, app, support, t)
    }

    func testALibraryFolderGameReadsItsSaveBesideTheApp() throws {
        let l = try layout(marker: true)
        let beside = l.library.appendingPathComponent("save/\(titleID)")
        XCTAssertEqual(l.transfer.macLocation(), .library(beside), "nothing yet: where the game will write")
        XCTAssertEqual(l.transfer.readMac(), SaveTransfer.Contents(), "no save yet")
        try write("a", beside.appendingPathComponent("slot0/data.bin"), date: newer)
        XCTAssertEqual(l.transfer.readMac(), SaveTransfer.Contents(folders: ["save"], newest: newer))
        XCTAssertEqual(l.transfer.macLocation(), .library(beside))
        XCTAssertEqual(l.transfer.macSource("save"), beside)
    }

    func testADefaultLocationGameReadsApplicationSupport() throws {
        let l = try layout(marker: false)
        let standard = SaveTransfer.legacyMacSave(titleID: titleID, support: l.support)
        XCTAssertEqual(l.transfer.macLocation(), .standard(standard))
        try write("a", standard.appendingPathComponent("data.bin"), date: older)
        try write("b", l.library.appendingPathComponent("save/\(titleID)/data.bin"), date: newer)   // not the layout: ignored
        XCTAssertEqual(l.transfer.readMac(), SaveTransfer.Contents(folders: ["save"], newest: older))
        XCTAssertEqual(l.transfer.macLocation(), .standard(standard))
    }

    /// Both exist: the game reads (and writes) the one beside the app, whatever the dates, and copies ~/Library only while
    /// that one is empty. So the window shows the library folder's save, and the ~/Library one only until the first start.
    func testALibraryFolderWithBothSavesPrefersTheOneBesideTheApp() throws {
        let l = try layout(marker: true)
        let standard = SaveTransfer.legacyMacSave(titleID: titleID, support: l.support)
        let beside = l.library.appendingPathComponent("save/\(titleID)")
        try write("old", standard.appendingPathComponent("data.bin"), date: newer)
        XCTAssertEqual(l.transfer.macLocation(), .pending(standard), "only the ~/Library save: the game copies it on its next start")
        XCTAssertEqual(l.transfer.readMac(), SaveTransfer.Contents(folders: ["save"], newest: newer))
        try fm.createDirectory(at: beside, withIntermediateDirectories: true)
        XCTAssertEqual(l.transfer.macLocation(), .pending(standard), "an empty folder beside the app counts as nothing, as for the game")
        try write("kept", beside.appendingPathComponent("data.bin"), date: older)
        XCTAssertEqual(l.transfer.macLocation(), .library(beside))
        XCTAssertEqual(l.transfer.readMac(), SaveTransfer.Contents(folders: ["save"], newest: older), "the library folder wins over a newer ~/Library save")
        XCTAssertEqual(l.transfer.macSource("save"), beside)
    }

    private let older = Date(timeIntervalSince1970: 1_700_000_000), newer = Date(timeIntervalSince1970: 1_760_000_000)

    func testTheMacSaveIsTheLaunchersFolderAndItsNewestFile() throws {
        let support = temporary.appendingPathComponent("Application Support")
        XCTAssertEqual(SaveTransfer.macSave(titleID: titleID, appPath: "", support: support).save.path, support.path + "/nxnative/" + titleID + "/save")
        let t = setUp(device: FakeDevice(temporary.appendingPathComponent("container")))
        XCTAssertEqual(t.readMac(), SaveTransfer.Contents(), "no save yet")
        try fm.createDirectory(at: t.mac.appendingPathComponent("save"), withIntermediateDirectories: true)
        XCTAssertEqual(t.readMac(), SaveTransfer.Contents(), "an empty save folder is no save")
        try write("a", t.mac.appendingPathComponent("save/slot0/data.bin"), date: older)
        try write("b", t.mac.appendingPathComponent("save_device/common.bin"), date: newer)
        try write("c", t.mac.appendingPathComponent("save.work/uncommitted.bin"), date: Date())   // a session's copy, not the save
        XCTAssertEqual(t.readMac(), SaveTransfer.Contents(folders: ["save", "save_device"], newest: newer))
    }

    func testTheDeviceSaveIsReadFromTheGamesFolderInTheContainer() throws {
        let device = FakeDevice(temporary.appendingPathComponent("container"))
        let t = setUp(device: device)
        let game = device.container.appendingPathComponent("Documents/games/" + titleID)
        try write("img", game.appendingPathComponent("romfs.img"), date: older)
        XCTAssertEqual(try t.readDevice(), SaveTransfer.Contents(), "installed, never saved")
        try write("d", game.appendingPathComponent("save/data.bin"), date: newer)
        XCTAssertEqual(try t.readDevice(), SaveTransfer.Contents(folders: ["save"], newest: newer))
        for call in device.calls {
            XCTAssertEqual(device.value("--domain-type", call), "appDataContainer")
            XCTAssertEqual(device.value("--domain-identifier", call), "com.example.game")
            XCTAssertEqual(device.value("--device", call), "00008150-AAAA")
        }
        device.reachable = false
        XCTAssertThrowsError(try t.readDevice()) { error in
            XCTAssertEqual(error as? SaveTransfer.Failure, .device("ERROR: The device is not connected. (com.apple.dt.CoreDeviceError error 4)"))
        }
    }

    func testDeviceToMacBacksUpTheMacSaveAndReplacesIt() throws {
        let device = FakeDevice(temporary.appendingPathComponent("container"))
        let t = setUp(device: device)
        try write("device save", device.container.appendingPathComponent("Documents/games/\(titleID)/save/data.bin"), date: newer)
        try write("mac save", t.mac.appendingPathComponent("save/data.bin"), date: older)
        try write("mac only", t.mac.appendingPathComponent("save/extra.bin"), date: older)
        let backup = try XCTUnwrap(try t.deviceToMac())
        XCTAssertEqual(backup.path, t.backups.path + "/\(stamp(1_800_000_000)) mac")
        XCTAssertEqual(read(backup.appendingPathComponent("save/data.bin")), "mac save")
        XCTAssertEqual(read(backup.appendingPathComponent("save/extra.bin")), "mac only")
        XCTAssertEqual(read(t.mac.appendingPathComponent("save/data.bin")), "device save")
        XCTAssertFalse(fm.fileExists(atPath: t.mac.appendingPathComponent("save/extra.bin").path), "the save is the device's, nothing older beside it")
        let left = try fm.contentsOfDirectory(atPath: t.mac.path).sorted()
        XCTAssertEqual(left, ["save", "save-backups"], "the incoming folder is gone")
        // A second copy in the same second gets a folder of its own
        let second = try XCTUnwrap(try t.deviceToMac())
        XCTAssertEqual(second.lastPathComponent, backup.lastPathComponent + " 2")
        XCTAssertEqual(read(second.appendingPathComponent("save/data.bin")), "device save")
    }

    func testDeviceToMacWithoutADeviceSaveLeavesTheMacAlone() throws {
        let device = FakeDevice(temporary.appendingPathComponent("container"))
        let t = setUp(device: device)
        try write("img", device.container.appendingPathComponent("Documents/games/\(titleID)/romfs.img"), date: older)
        try write("mac save", t.mac.appendingPathComponent("save/data.bin"), date: older)
        XCTAssertThrowsError(try t.deviceToMac()) { XCTAssertEqual($0 as? SaveTransfer.Failure, .noDeviceSave) }
        XCTAssertEqual(read(t.mac.appendingPathComponent("save/data.bin")), "mac save")
        XCTAssertFalse(fm.fileExists(atPath: t.backups.path))
        // A copy that fails partway leaves the Mac save too
        try write("device save", device.container.appendingPathComponent("Documents/games/\(titleID)/save/data.bin"), date: newer)
        device.failCopyFrom = true
        XCTAssertThrowsError(try t.deviceToMac())
        XCTAssertEqual(read(t.mac.appendingPathComponent("save/data.bin")), "mac save")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: t.mac.path), ["save"])
    }

    func testMacToDeviceCopiesTheDeviceSaveToTheMacFirst() throws {
        let device = FakeDevice(temporary.appendingPathComponent("container"))
        let t = setUp(device: device)
        let game = device.container.appendingPathComponent("Documents/games/\(titleID)")
        try write("img", game.appendingPathComponent("romfs.img"), date: older)
        try write("device save", game.appendingPathComponent("save/data.bin"), date: older)
        try write("device stale", game.appendingPathComponent("save/stale.bin"), date: older)
        try write("mac save", t.mac.appendingPathComponent("save/data.bin"), date: newer)
        let backup = try XCTUnwrap(try t.macToDevice())
        XCTAssertTrue(backup.lastPathComponent.hasSuffix(" device"))
        XCTAssertEqual(read(backup.appendingPathComponent("save/data.bin")), "device save")
        XCTAssertEqual(read(backup.appendingPathComponent("save/stale.bin")), "device stale")
        XCTAssertEqual(read(game.appendingPathComponent("save/data.bin")), "mac save")
        XCTAssertEqual(read(game.appendingPathComponent("save/stale.bin")), "device stale", "merged: devicectl cannot delete one file, and the backup has it")
        XCTAssertEqual(read(game.appendingPathComponent("romfs.img")), "img", "the game files beside the save stay")
        XCTAssertFalse(device.calls.contains { $0.contains("--remove-existing-content") }, "the flag deletes the destination's siblings (#250)")
        let copyTo = try XCTUnwrap(device.calls.first { $0.prefix(3) == ["device", "copy", "to"] })
        XCTAssertEqual(device.value("--destination", copyTo), "Documents/games/\(titleID)/save", "never the game's folder, which holds romfs.img")
        XCTAssertEqual(device.value("--source", copyTo), t.mac.appendingPathComponent("save").path)
    }

    /// #250: a save push must leave the game data in Documents and the game's folder where they are.
    func testMacToDeviceLeavesTheGameDataOnTheDevice() throws {
        let device = FakeDevice(temporary.appendingPathComponent("container"))
        let t = setUp(device: device)
        let docs = device.container.appendingPathComponent("Documents"), game = docs.appendingPathComponent("games/\(titleID)")
        try write("image", docs.appendingPathComponent("romfs.img"), date: older)
        try write("env", docs.appendingPathComponent("env.txt"), date: older)
        try write("game image", game.appendingPathComponent("romfs.img"), date: older)
        try write("dlc", game.appendingPathComponent("aoc/a.bin"), date: older)
        try write("cheat", game.appendingPathComponent("cheats/x.txt"), date: older)
        try write("device save", game.appendingPathComponent("save/data.bin"), date: older)
        try write("mac save", t.mac.appendingPathComponent("save/data.bin"), date: newer)
        _ = try t.macToDevice()
        XCTAssertEqual(read(game.appendingPathComponent("save/data.bin")), "mac save")
        XCTAssertEqual(read(docs.appendingPathComponent("romfs.img")), "image")
        XCTAssertEqual(read(docs.appendingPathComponent("env.txt")), "env")
        XCTAssertEqual(read(game.appendingPathComponent("romfs.img")), "game image")
        XCTAssertEqual(read(game.appendingPathComponent("aoc/a.bin")), "dlc")
        XCTAssertEqual(read(game.appendingPathComponent("cheats/x.txt")), "cheat")
    }

    /// The stand-in itself: with the flag it wipes the siblings, so a regression to it cannot pass unnoticed.
    func testTheStandInWipesSiblingsWhenTheFlagIsPassed() throws {
        let device = FakeDevice(temporary.appendingPathComponent("container"))
        try write("image", device.container.appendingPathComponent("Documents/romfs.img"), date: older)
        try write("x", temporary.appendingPathComponent("src/a.bin"), date: older)
        let args = SaveTransfer.copyToCommand(device: "D", bundle: "b", source: temporary.appendingPathComponent("src").path, destination: "Documents/save") + ["--remove-existing-content", "true"]
        XCTAssertTrue(device.control.run(args).ok)
        XCTAssertFalse(fm.fileExists(atPath: device.container.appendingPathComponent("Documents/romfs.img").path))
    }

    func testMacToDeviceReplacesNothingWhenTheBackupFails() throws {
        let device = FakeDevice(temporary.appendingPathComponent("container"))
        let t = setUp(device: device)
        let game = device.container.appendingPathComponent("Documents/games/\(titleID)")
        try write("device save", game.appendingPathComponent("save/data.bin"), date: older)
        try write("mac save", t.mac.appendingPathComponent("save/data.bin"), date: newer)
        device.failCopyFrom = true
        XCTAssertThrowsError(try t.macToDevice())
        XCTAssertEqual(read(game.appendingPathComponent("save/data.bin")), "device save")
        XCTAssertFalse(device.calls.contains { $0.prefix(3) == ["device", "copy", "to"] })
        // No Mac save: nothing is asked of the device at all
        try fm.removeItem(at: t.mac.appendingPathComponent("save"))
        device.clearCalls()
        XCTAssertThrowsError(try t.macToDevice()) { XCTAssertEqual($0 as? SaveTransfer.Failure, .noMacSave) }
        XCTAssertTrue(device.calls.isEmpty)
        // A device that is not reachable: the copy stops before anything is replaced
        device.failCopyFrom = false
        device.reachable = false
        try write("mac save", t.mac.appendingPathComponent("save/data.bin"), date: newer)
        XCTAssertThrowsError(try t.macToDevice())
        XCTAssertEqual(device.calls.count, 1)
    }

    func testACopyNestedInItsDestinationIsTheSaveFolderAllTheSame() throws {
        let device = FakeDevice(temporary.appendingPathComponent("container"))
        device.nested = true
        let t = setUp(device: device)
        try write("device save", device.container.appendingPathComponent("Documents/games/\(titleID)/save/sub/data.bin"), date: newer)
        _ = try t.deviceToMac()
        XCTAssertEqual(read(t.mac.appendingPathComponent("save/sub/data.bin")), "device save")
    }

    func testTheListingsDatesAreReadWhereverTheyAreNested() throws {
        let json = """
        {"info": {"outcome": "success"}, "result": {"files": [
          {"name": "save", "fileType": "directory", "modificationDate": "2030-01-01T00:00:00Z"},
          {"name": "a.bin", "fileType": "file", "metadata": {"modificationDate": "2025-05-01T10:00:00.250Z"}},
          {"name": "b.bin", "fileType": "file", "modificationDate": "2025-06-01T10:00:00Z"}
        ]}}
        """
        let parsed = try XCTUnwrap(SaveTransfer.parseListing(Data(json.utf8)))
        XCTAssertEqual(parsed.files, 2, "the directory is not a file")
        XCTAssertEqual(parsed.newest, ISO8601DateFormatter().date(from: "2025-06-01T10:00:00Z"))
        XCTAssertNil(SaveTransfer.parseListing(Data("not json".utf8)))
        XCTAssertEqual(SaveTransfer.parseListing(Data(#"{"result": {"files": []}}"#.utf8))?.files, 0)
        XCTAssertEqual(SaveTransfer.date(1_700_000_000.0), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(SaveTransfer.date(700_000_000.0), Date(timeIntervalSinceReferenceDate: 700_000_000))
    }

    func testTheNewerSaveIsMarked() {
        XCTAssertNil(SaveTransfer.newer(mac: nil, device: nil))
        XCTAssertEqual(SaveTransfer.newer(mac: older, device: nil), .mac)
        XCTAssertEqual(SaveTransfer.newer(mac: nil, device: older), .device)
        XCTAssertEqual(SaveTransfer.newer(mac: older, device: newer), .device)
        XCTAssertEqual(SaveTransfer.newer(mac: newer, device: older), .mac)
        XCTAssertNil(SaveTransfer.newer(mac: older, device: older.addingTimeInterval(1)), "written together")
    }

    func testARunningBuildOfTheGameIsFoundByItsTitleID() throws {
        func app(_ name: String, _ id: String?) throws -> URL {
            let url = temporary.appendingPathComponent(name + ".app")
            try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let info: [String: Any] = id.map { ["DMTitleID": $0] } ?? ["CFBundleName": name]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
            return url
        }
        let other = try app("Other", "01007EF00011E000"), finder = try app("Finder", nil), game = try app("Hades", titleID.lowercased())
        XCTAssertFalse(SaveTransfer.running(titleID: titleID, apps: [other, finder]))
        XCTAssertTrue(SaveTransfer.running(titleID: titleID, apps: [other, finder, game]))
    }

    func testDevicectlsLastErrorLineIsTheMessage() {
        XCTAssertEqual(SaveTransfer.lastLine("Acquired tunnel\nERROR: Failed to copy\n  underlying: x\n"), "ERROR: Failed to copy")
        XCTAssertEqual(SaveTransfer.lastLine("one\ntwo\n"), "two")
        XCTAssertEqual(SaveTransfer.lastLine(""), "devicectl")
    }

    private func stamp(_ seconds: TimeInterval) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }
}

private extension SaveTransfer {
    /// The ~/Library layout's game folder, which holds save, save_device and save-backups side by side
    var mac: URL { macSave.deletingLastPathComponent() }
}
