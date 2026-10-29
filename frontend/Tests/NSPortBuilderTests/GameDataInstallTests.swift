import AppKit
import SwiftUI
import XCTest
@testable import NSPortBuilder

/// #99: game data goes to the device once per game and version. devicectl is a stand-in, so no test reaches a device.
final class GameDataInstallTests: XCTestCase {
    private let fm = FileManager.default
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("nxnative-data-tests-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: temporary) }

    static func line(size: Int64 = 14_700_000_000, index: String = "00aa11bb22cc33dd", version: String = "1.9.0") -> String {
        "DMROMFSID1 title=01007EF00011E000 version=\(version) build=1 size=\(size) index=\(index)\n"
    }
    static func id(_ size: Int64 = 14_700_000_000, index: String = "00aa11bb22cc33dd", version: String = "1.9.0") -> RomFSIdentity {
        RomFSIdentity(line(size: size, index: index, version: version))!
    }

    func testIdentityParsesTheToolsLine() {
        let i = Self.id()
        XCTAssertEqual(i.size, 14_700_000_000)
        XCTAssertEqual(i.index, "00aa11bb22cc33dd")
        XCTAssertEqual(i.version, "1.9.0")
        XCTAssertNil(RomFSIdentity("uploading\n"))
        XCTAssertNil(RomFSIdentity("DMROMFSID1 title=x version=1 build=1"))
        XCTAssertEqual(RomFSIdentity("DMROMFSID1 title=x version=- build=- size=5 index=ab")?.version, "")
    }

    func testSameImageIgnoresTheNamingFields() {
        XCTAssertTrue(Self.id(version: "1.9.0").sameImage(as: Self.id(version: "2.0.0")))
        XCTAssertFalse(Self.id().sameImage(as: Self.id(index: "ffffffffffffffff")))
        XCTAssertFalse(Self.id().sameImage(as: Self.id(5)))
    }

    func testDecision() {
        let b = Self.id()
        XCTAssertEqual(GameDataPlan.decide(build: b, mac: b, device: nil), .upload(bytes: b.size, version: "1.9.0", replacing: false))
        XCTAssertEqual(GameDataPlan.decide(build: b, mac: b, device: Self.id()), .present(version: "1.9.0"))
        XCTAssertEqual(GameDataPlan.decide(build: b, mac: b, device: Self.id(index: "0123456789abcdef", version: "1.8.0")), .upload(bytes: b.size, version: "1.9.0", replacing: true))
        XCTAssertEqual(GameDataPlan.decide(build: b, mac: Self.id(index: "0123456789abcdef"), device: Self.id()), .imageChanged)
        XCTAssertEqual(GameDataPlan.decide(build: nil, mac: b, device: nil), .noIdentity)
        XCTAssertEqual(GameDataPlan.decide(build: b, mac: nil, device: b), .noIdentity)
    }

    func testMessages() {
        XCTAssertEqual(GameDataPlan.present(version: "1.9.0").message(device: "Anna's iPhone", lang: .en), "Game data is already on Anna's iPhone (1.9.0), only the app was installed")
        XCTAssertEqual(GameDataPlan.present(version: "").message(device: "iPhone", lang: .en), "Game data is already on iPhone, only the app was installed")
        XCTAssertEqual(GameDataPlan.upload(bytes: 14_700_000_000, version: "1.9.0", replacing: false).message(device: "iPhone", lang: .en), "Uploading game data (14.7 GB) once for this version")
        XCTAssertEqual(GameDataPlan.upload(bytes: 14_700_000_000, version: "1.9.0", replacing: true).message(device: "iPhone", lang: .en),
                       "The game data on iPhone is another version, uploading the new one (14.7 GB)")
        XCTAssertEqual(GameDataPlan.upload(bytes: 1, version: "1.9.0", replacing: false).doneMessage(device: "iPhone", lang: .en), "Game data uploaded to iPhone (1.9.0)")
        XCTAssertEqual(GameDataInstall.amount(820_000_000), "820 MB")
    }

    func testEveryStringHasAllColumnsAndNoSemicolon() {
        let keys = ["checkStage", "present", "presentNoVersion", "upload", "uploadNew", "uploaded", "uploadedNoVersion", "imageChanged", "noIdentity", "locked", "noDevice", "noSpace", "failed"]
        for key in keys {
            let en = L10n.string("dev.data." + key, .en)
            XCTAssertNotEqual(en, "dev.data." + key)
            for lang in [Lang.zh, .en, .sv] {
                let s = L10n.string("dev.data." + key, lang)
                XCTAssertFalse(s.isEmpty)
                XCTAssertFalse(s.contains(";") || s.contains("；"), s)
            }
            XCTAssertNotEqual(L10n.string("dev.data." + key, .sv), en, key + " has no Swedish text")
            XCTAssertEqual(en.components(separatedBy: "%").count, L10n.string("dev.data." + key, .sv).components(separatedBy: "%").count, key + " placeholders differ")
        }
    }

    func testDeviceProblemsNameTheFix() {
        XCTAssertEqual(DeviceProblem.of("ERROR: The device is locked. (com.apple.dt.CoreDeviceError error 1)"), .locked)
        XCTAssertEqual(DeviceProblem.of("error: No space left on device"), .noSpace)
        XCTAssertEqual(DeviceProblem.of("ERROR: No devices found matching the provided criteria"), .noDevice)
        XCTAssertEqual(DeviceProblem.of("error: something else"), .other)
        XCTAssertTrue(DeviceProblem.locked.message(device: "iPhone", bytes: 0, detail: "", lang: .en).contains("Unlock"))
        XCTAssertTrue(DeviceProblem.noSpace.message(device: "iPhone", bytes: 14_700_000_000, detail: "", lang: .en).contains("14.7 GB"))
        XCTAssertTrue(DeviceProblem.noDevice.message(device: "iPhone", bytes: 0, detail: "", lang: .en).contains("cable"))
        XCTAssertTrue(DeviceProblem.other.message(device: "iPhone", bytes: 0, detail: "boom", lang: .en).contains("boom"))
    }

    func testBuildArguments() {
        XCTAssertEqual(GameDataInstall.romfsArguments(bundled: false, supported: true), ["--romfs", "separate", "--keep-extracted"])
        XCTAssertEqual(GameDataInstall.romfsArguments(bundled: true, supported: true), [])
        XCTAssertEqual(GameDataInstall.romfsArguments(bundled: false, supported: false), [])
    }

    func testUploadCommandsTargetThePerGameFolder() {
        let item = GameDataInstall.items(image: "/work/extract/v0/RomFS.img")[0]
        XCTAssertEqual(GameDataInstall.upload(item, xcrun: "/usr/bin/xcrun", device: "UDID", bundle: "org.nxnative.x", titleID: "01007EF00011E000"),
                       ["/usr/bin/xcrun", "devicectl", "device", "copy", "to", "--device", "UDID", "--source", "/work/extract/v0/RomFS.img",
                        "--destination", "Documents/games/01007EF00011E000/romfs.img", "--domain-type", "appDataContainer", "--domain-identifier", "org.nxnative.x"])
        XCTAssertEqual(GameDataInstall.uploadStep("Copying 45%")?.percent, 45)
        XCTAssertNil(GameDataInstall.uploadStep("Copying"))
    }

    func testImageOfTheExtraction() throws {
        let work = temporary.appendingPathComponent("0100_build")
        XCTAssertNil(GameDataInstall.image(inWork: work.path))
        try fm.createDirectory(at: work.appendingPathComponent("extract/v0"), withIntermediateDirectories: true)
        try Data([1]).write(to: work.appendingPathComponent("extract/v0/RomFS.img"))
        XCTAssertEqual(GameDataInstall.image(inWork: work.path), work.path + "/extract/v0/RomFS.img")
        try fm.createDirectory(at: work.appendingPathComponent("aoc"), withIntermediateDirectories: true)
        XCTAssertNil(GameDataInstall.image(inWork: work.path), "a game with DLC keeps the earlier route until DLC rides along")
    }

    /// The device's data container as a folder: copy from reads a file of it, copy to writes one.
    private func container(id: String?) -> (DeviceControl, URL) {
        let root = temporary.appendingPathComponent("container-" + UUID().uuidString)
        let folder = root.appendingPathComponent("Documents/games/01007EF00011E000")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let id { try? id.write(to: folder.appendingPathComponent("romfs.id"), atomically: true, encoding: .utf8) }
        let control = DeviceControl { args in
            func v(_ f: String) -> String { args[args.firstIndex(of: f)! + 1] }
            if args.starts(with: ["device", "copy", "from"]) {
                let src = root.appendingPathComponent(v("--source"))
                guard (try? self.fm.copyItem(at: src, to: URL(fileURLWithPath: v("--destination")))) != nil else { return (false, "ERROR: file not found") }
                return (true, "")
            }
            if args.starts(with: ["device", "copy", "to"]) {
                let dst = root.appendingPathComponent(v("--destination"))
                let src = URL(fileURLWithPath: v("--source"))
                for name in (try? self.fm.contentsOfDirectory(atPath: src.path)) ?? [] {
                    try? self.fm.removeItem(at: dst.appendingPathComponent(name))
                    try? self.fm.copyItem(at: src.appendingPathComponent(name), to: dst.appendingPathComponent(name))
                }
                return (true, "")
            }
            return (false, "unexpected")
        }
        return (control, folder)
    }

    func testReadingWhatTheDeviceHolds() {
        let tid = "01007EF00011E000"
        var (control, _) = container(id: Self.line())
        var r = GameDataInstall.readDeviceIdentity(devicectl: control, device: "U", bundle: "b", titleID: tid, scratch: temporary)
        XCTAssertEqual(r.identity, Self.id())
        XCTAssertNil(r.problem)
        (control, _) = container(id: nil)
        r = GameDataInstall.readDeviceIdentity(devicectl: control, device: "U", bundle: "b", titleID: tid, scratch: temporary)
        XCTAssertNil(r.identity)
        XCTAssertNil(r.problem, "a missing file means the image goes up")
        let locked = DeviceControl { _ in (false, "ERROR: The device is locked.") }
        r = GameDataInstall.readDeviceIdentity(devicectl: locked, device: "U", bundle: "b", titleID: tid, scratch: temporary)
        XCTAssertEqual(r.problem?.0, .locked)
    }

    func testTheMarkerInvalidatesTheIdentityBeforeAnUpload() throws {
        let (control, folder) = container(id: Self.line())
        let r = GameDataInstall.writeDeviceIdentity(GameDataInstall.marker, devicectl: control, device: "U", bundle: "b", titleID: "01007EF00011E000", scratch: temporary)
        XCTAssertTrue(r.ok)
        let back = GameDataInstall.readDeviceIdentity(devicectl: control, device: "U", bundle: "b", titleID: "01007EF00011E000", scratch: temporary)
        XCTAssertNil(back.identity)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("romfs.id"), encoding: .utf8), "uploading\n")
        XCTAssertTrue(GameDataInstall.writeDeviceIdentity(Self.line(), devicectl: control, device: "U", bundle: "b", titleID: "01007EF00011E000", scratch: temporary).ok)
        XCTAssertEqual(GameDataInstall.readDeviceIdentity(devicectl: control, device: "U", bundle: "b", titleID: "01007EF00011E000", scratch: temporary).identity, Self.id())
    }

    func testTheRepositoryToolsIdentityMatchesTheLauncherParser() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        guard fm.fileExists(atPath: repo + "/" + BuildModel.romfsImageTool), fm.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no repository checkout") }
        // a tiny image in the tool's format: header (magic, index offset, index size, 0), then the index
        var head = Data("DMROMFS1".utf8)
        for v in [UInt64(32), 16, 0] { var x = v.littleEndian; head.append(Data(bytes: &x, count: 8)) }
        let img = temporary.appendingPathComponent("RomFS.img")
        try (head + Data(repeating: 7, count: 16)).write(to: img)
        let text = try XCTUnwrap(GameDataInstall.macIdentity(python: "/usr/bin/python3", repo: repo, image: img.path))
        let i = try XCTUnwrap(RomFSIdentity(text), text)
        XCTAssertEqual(i.size, 48)
    }

    /// Opt-in native rendering of the install card (NX_LAUNCHER_CAPTURE_DIR).
    @MainActor func testRenderInstallCardForScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = BuildModel()
        let oldRepo = UserDefaults.standard.object(forKey: "repoPath"), oldDevice = UserDefaults.standard.object(forKey: "installDevice")
        defer { UserDefaults.standard.set(oldRepo, forKey: "repoPath"); UserDefaults.standard.set(oldDevice, forKey: "installDevice") }
        model.lang = .en
        model.outDir = temporary.path
        model.depsChecked = true
        model.deps = [BuildModel.Dep(id: "test", name: "Xcode", hint: "", present: true, installCmd: [])]
        model.target = "ios"
        model.devices = [AppleDevice(id: "UDID", name: "Anna's iPhone", model: "iPhone 17 Pro", os: "26.0", reachable: true)]
        model.installDevice = "UDID"
        model.installedAppPath = temporary.appendingPathComponent("DmIOS.app").path
        model.archivePath = temporary.appendingPathComponent("extract/v0").path
        let library = GameLibrary(file: temporary.appendingPathComponent("preview.json"))
        func capture(_ name: String) throws {
            let view = ContentView(model: model, library: library, initialPage: .builds, performStartupChecks: false)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 2300), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        let present = GameDataPlan.present(version: "1.9.0"), upload = GameDataPlan.upload(bytes: 14_700_000_000, version: "1.9.0", replacing: false)
        model.running = true
        model.stages = [Stage(id: 1002, name: "Install on Anna's iPhone", state: .done),
                        Stage(id: 1003, name: upload.message(device: "Anna's iPhone", lang: .en), state: .running, detail: "uploading", percent: 38, started: Date())]
        try capture("install-uploading")
        model.running = false; model.done = true
        model.installedOn = "UDID"
        model.stages = [Stage(id: 1002, name: "Install on Anna's iPhone", state: .done), Stage(id: 1008, name: "Check the game data on Anna's iPhone", state: .done)]
        model.gameDataNote = present.doneMessage(device: "Anna's iPhone", lang: .en)
        try capture("install-data-present")
        model.gameDataNote = upload.doneMessage(device: "Anna's iPhone", lang: .en)
        try capture("install-data-uploaded")
        model.installedOn = ""; model.done = false; model.gameDataNote = ""
        model.doneNote = DeviceProblem.noSpace.message(device: "Anna's iPhone", bytes: 14_700_000_000, detail: "", lang: .en)
        model.stages = [Stage(id: 1002, name: "Install on Anna's iPhone", state: .done), Stage(id: 1003, name: upload.message(device: "Anna's iPhone", lang: .en), state: .failed)]
        try capture("install-no-space")
    }
}
