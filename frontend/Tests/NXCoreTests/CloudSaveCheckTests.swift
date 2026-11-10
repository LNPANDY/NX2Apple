import XCTest
@testable import NXCore

/// #957: the check before a start compares this Mac's save, the cloud's and the last synced one as dm/host/save_sync.c does.
final class CloudSaveCheckTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-save-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func save(_ hash: String?) -> CloudSaveCheck.Save { .init(hash: hash) }

    // ---- the six cases of #957 ----

    func testTheSameSaveStartsTheGame() {
        XCTAssertEqual(CloudSaveCheck.decide(local: save("A"), base: "A", cloud: save("A")), .same)
        XCTAssertEqual(CloudSaveCheck.decide(local: save("B"), base: "A", cloud: save("B")), .same, "both moved to the same save")
        XCTAssertEqual(CloudSaveCheck.decide(local: .empty, base: nil, cloud: .empty), .same, "no save anywhere")
        XCTAssertFalse(CloudSaveCheck.Outcome.same.asks)
    }

    func testOnlyTheCloudsChangedIsBroughtInWithoutAsking() {
        XCTAssertEqual(CloudSaveCheck.decide(local: save("A"), base: "A", cloud: save("C")), .onlyCloudChanged)
        XCTAssertEqual(CloudSaveCheck.decide(local: .empty, base: nil, cloud: save("C")), .onlyCloudChanged, "nothing on this Mac: nothing to lose")
        XCTAssertFalse(CloudSaveCheck.Outcome.onlyCloudChanged.asks)
    }

    func testOnlyThisMacsChangedIsSentWithoutAsking() {
        XCTAssertEqual(CloudSaveCheck.decide(local: save("L"), base: "A", cloud: save("A")), .onlyLocalChanged)
        XCTAssertFalse(CloudSaveCheck.Outcome.onlyLocalChanged.asks)
    }

    func testBothChangedAsks() {
        XCTAssertEqual(CloudSaveCheck.decide(local: save("L"), base: "A", cloud: save("C")), .bothChanged)
        XCTAssertEqual(CloudSaveCheck.decide(local: save("L"), base: nil, cloud: save("C")), .bothChanged,
                       "this Mac never synced and both have a save: the first play on a Mac that has a save of its own")
        XCTAssertTrue(CloudSaveCheck.Outcome.bothChanged.asks)
    }

    func testNoSaveInTheCloudStartsTheGame() {
        XCTAssertEqual(CloudSaveCheck.decide(local: save("L"), base: nil, cloud: .empty), .noCloudSave)
        XCTAssertEqual(CloudSaveCheck.decide(local: save("L"), base: "A", cloud: .empty), .noCloudSave)
        XCTAssertFalse(CloudSaveCheck.Outcome.noCloudSave.asks)
    }

    func testTheCloudUnreadableAsks() {
        XCTAssertEqual(CloudSaveCheck.decide(local: save("L"), base: "A", cloud: nil), .unreadable)
        XCTAssertEqual(CloudSaveCheck.decide(local: .empty, base: nil, cloud: nil), .unreadable, "even with nothing here: the cloud may hold progress")
        XCTAssertTrue(CloudSaveCheck.Outcome.unreadable.asks)
    }

    // ---- the choice the engine reads ----

    func testTheChoiceNamesTheCloudSaveItWasMadeOn() {
        let cloud = save("0123456789abcdef0123456789abcdef")
        XCTAssertEqual(CloudSaveCheck.environment(.cloud, cloud: cloud), ["DM_SAVE_SYNC_CHOICE": "cloud:0123456789abcdef0123456789abcdef"])
        XCTAssertEqual(CloudSaveCheck.environment(.local, cloud: cloud), ["DM_SAVE_SYNC_CHOICE": "local:0123456789abcdef0123456789abcdef"])
        XCTAssertEqual(CloudSaveCheck.environment(.local, cloud: .empty), ["DM_SAVE_SYNC_CHOICE": "local:none"])
        XCTAssertEqual(CloudSaveCheck.environment(.offline, cloud: nil), ["DM_SAVE_SYNC_CHOICE": "offline"])
        XCTAssertEqual(CloudSaveCheck.environment(.cloud, cloud: .empty), [:], "no cloud save to bring in: no choice")
    }

    // ---- reading the three saves ----

    func testTheBaseIsTheLastValidLine() throws {
        let s = root.appendingPathComponent("save")
        XCTAssertNil(CloudSaveCheck.base(save: s))
        try "# save sync\nbase\t0123456789abcdef0123456789abcdef\nbase\tnot a hash\n".write(toFile: s.path + ".sync", atomically: true, encoding: .utf8)
        XCTAssertEqual(CloudSaveCheck.base(save: s), "0123456789abcdef0123456789abcdef")
        try "base\tABCDEF0123456789abcdef0123456789\n".write(toFile: s.path + ".sync", atomically: true, encoding: .utf8)
        XCTAssertNil(CloudSaveCheck.base(save: s), "save_sync.c writes lowercase hex only")
    }

    /// The fixture's hash is what the engine's ss_scan gives for it (a small C program on dm/host/save_sync.c): folders, a guest name,
    /// the device save; .DS_Store and dates are not part of it.
    func testThisMacsSaveHasTheEnginesHash() throws {
        let s = root.appendingPathComponent("save")
        let fm = FileManager.default
        XCTAssertEqual(CloudSaveCheck.localSave(save: s), .empty, "no folder yet: no save, as ss_scan sees it")
        try fm.createDirectory(at: s.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: s.appendingPathComponent("empty"), withIntermediateDirectories: true)
        XCTAssertEqual(CloudSaveCheck.localSave(save: s), .empty, "folders and no file: no save")
        try fm.createDirectory(atPath: s.path + "_device", withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: s.appendingPathComponent("a"))
        let b = s.appendingPathComponent("sub/b")
        try Data("xy".utf8).write(to: b)
        XCTAssertEqual(setxattr(b.path, "org.d2rmobile.guest-name", "B", 1, 0, XATTR_NOFOLLOW), 0)
        try Data("finder".utf8).write(to: s.appendingPathComponent(".DS_Store"))
        try Data("dev".utf8).write(to: URL(fileURLWithPath: s.path + "_device/d"))
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: when], ofItemAtPath: b.path)
        try fm.setAttributes([.modificationDate: when.addingTimeInterval(-50)], ofItemAtPath: s.appendingPathComponent("a").path)
        try fm.setAttributes([.modificationDate: when.addingTimeInterval(-60)], ofItemAtPath: s.path + "_device/d")
        let scanned = try XCTUnwrap(CloudSaveCheck.localSave(save: s))
        XCTAssertEqual(scanned.hash, "13ccb164be7f3e628ab478bd309e41d8")
        XCTAssertEqual(scanned.saved, when, "the newest file's date")
        try Data("hellO".utf8).write(to: s.appendingPathComponent("a"))
        XCTAssertNotEqual(CloudSaveCheck.localSave(save: s)?.hash, "13ccb164be7f3e628ab478bd309e41d8", "one changed byte, another hash")
    }

    /// A header as ss_pack writes it, and files that are not packed saves.
    func testTheCloudFilesHeader() throws {
        let file = root.appendingPathComponent("save.dmsync")
        var data = Data("DMSYNC1\n".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian, Array.init))
        data.append(Data("13ccb164be7f3e628ab478bd309e41d8".utf8))
        data.append(contentsOf: withUnsafeBytes(of: Int64(1_700_000_000).littleEndian, Array.init))
        var title = Data("0100ABCDEF000000".utf8); title.count = 24; data.append(title)
        var device = Data("iPhone17,1".utf8); device.count = 64; data.append(device)
        data.append(Data("DMSYNCE\n".utf8))
        try data.write(to: file)
        let cloud = try XCTUnwrap(CloudSaveCheck.cloudSave(file: file))
        XCTAssertEqual(cloud, .init(hash: "13ccb164be7f3e628ab478bd309e41d8", saved: Date(timeIntervalSince1970: 1_700_000_000), device: "iPhone17,1"))
        XCTAssertEqual(CloudSaveCheck.cloudTitle(file: file), "0100ABCDEF000000")
        try data.dropLast().write(to: file)
        XCTAssertNil(CloudSaveCheck.cloudSave(file: file), "cut off: its end marker is missing")
        try Data("not a save".utf8).write(to: file)
        XCTAssertNil(CloudSaveCheck.cloudSave(file: file))
    }

    // ---- the download ----

    func testTheDownloadOfAFileThatIsHere() throws {
        let folder = root.appendingPathComponent("Saves/0100ABCDEF000000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("save.dmsync")
        XCTAssertEqual(CoordinatedCloudFetch().fetch(file) { false }, .missing, "a folder without the file: the cloud has no save")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(CoordinatedCloudFetch().fetch(file) { false }, .ready)
        let elsewhere = root.appendingPathComponent("Gone/0100ABCDEF000000/save.dmsync")
        guard case .failed = CoordinatedCloudFetch().fetch(elsewhere, cancelled: { false }) else { return XCTFail("no folder at all is no answer") }
    }
}
