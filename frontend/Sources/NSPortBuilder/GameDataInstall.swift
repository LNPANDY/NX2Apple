import Foundation

/// The identity line of a RomFS image (dm/tools/romfs_image.py --identity, format in dm/host/romfs_identity.h):
/// `DMROMFSID1 title=<id> version=<text> build=<text> size=<bytes> index=<16 hex digits>`.
/// Size and index decide whether two lines name the same image, the rest only names it in messages.
struct RomFSIdentity: Equatable {
    let size: Int64
    let index: String
    let version: String

    static let magic = "DMROMFSID1"

    init?(_ text: String) {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard parts.first == Self.magic else { return nil }
        var fields: [String: String] = [:]
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            fields[String(p[..<eq])] = String(p[p.index(after: eq)...])
        }
        guard let size = fields["size"].flatMap({ Int64($0) }), let index = fields["index"], !index.isEmpty else { return nil }
        self.size = size
        self.index = index
        let v = fields["version"] ?? ""
        self.version = v == "-" ? "" : v
    }

    func sameImage(as other: RomFSIdentity) -> Bool { size == other.size && index == other.index }
}

/// What to do about the game data when an app built with `--romfs separate` goes onto a device.
enum GameDataPlan: Equatable {
    /// The device already holds this image: install the app only.
    case present(version: String)
    /// Send the image: nothing there (`replacing` false) or another image there.
    case upload(bytes: Int64, version: String, replacing: Bool)
    /// The build carries no identity, or the image cannot be read: the earlier full copy applies.
    case noIdentity
    /// The image on this Mac is not the one the app was built for.
    case imageChanged

    /// The decision, from the three identities: the app's own (romfs.id in the built app), the image on this Mac, and the one the
    /// launcher left on the device after its last complete upload (nil when there is none or it cannot be read).
    static func decide(build: RomFSIdentity?, mac: RomFSIdentity?, device: RomFSIdentity?) -> GameDataPlan {
        guard let build, let mac else { return .noIdentity }
        guard build.sameImage(as: mac) else { return .imageChanged }
        guard let device else { return .upload(bytes: mac.size, version: build.version, replacing: false) }
        return device.sameImage(as: build) ? .present(version: build.version)
                                           : .upload(bytes: mac.size, version: build.version, replacing: true)
    }

    /// The sentence for the install card and the stage row.
    func message(device: String, lang: Lang) -> String {
        let t = { L10n.string($0, lang) }
        switch self {
        case let .present(version):
            return version.isEmpty ? String(format: t("dev.data.presentNoVersion"), device)
                                   : String(format: t("dev.data.present"), device, version)
        case let .upload(bytes, _, replacing):
            return replacing ? String(format: t("dev.data.uploadNew"), GameDataInstall.amount(bytes), device)
                             : String(format: t("dev.data.upload"), GameDataInstall.amount(bytes))
        case .noIdentity: return ""
        case .imageChanged: return t("dev.data.imageChanged")
        }
    }

    /// The card's line once the install is through.
    func doneMessage(device: String, lang: Lang) -> String {
        switch self {
        case .present: return message(device: device, lang: lang)
        case let .upload(bytes, version, _):
            return String(format: L10n.string(version.isEmpty ? "dev.data.uploadedNoVersion" : "dev.data.uploaded", lang), device, version.isEmpty ? GameDataInstall.amount(bytes) : version)
        default: return ""
        }
    }
}

/// What a devicectl failure means for the player, from its words.
enum DeviceProblem: Equatable {
    case locked, noDevice, noSpace, other

    static func of(_ output: String) -> DeviceProblem {
        let s = output.lowercased()
        if s.contains("locked") || s.contains("passcode") { return .locked }
        if ["no space", "not enough space", "out of space", "enospc", "insufficient storage", "disk full", "not enough storage"].contains(where: s.contains) { return .noSpace }
        if ["not connected", "unavailable", "no devices", "could not be found", "not paired", "cannot connect", "no such device", "timed out", "is not available"].contains(where: s.contains) { return .noDevice }
        return .other
    }

    /// The message naming the fix. `detail` is devicectl's last line, only used when the cause is unknown.
    func message(device: String, bytes: Int64, detail: String, lang: Lang) -> String {
        let t = { L10n.string($0, lang) }
        switch self {
        case .locked: return String(format: t("dev.data.locked"), device)
        case .noDevice: return String(format: t("dev.data.noDevice"), device)
        case .noSpace: return String(format: t("dev.data.noSpace"), device, GameDataInstall.amount(bytes))
        case .other: return String(format: t("dev.data.failed"), detail)
        }
    }
}

/// One thing to put into the game's folder on the device (Documents/games/<title ID>/). The upload takes a list of these, so
/// more than the image can ride along later.
struct GameDataItem: Equatable {
    let source: String
    let destination: String   // relative to the game's folder on the device
}

/// Game data that goes to the device once per game and version (#99): the app is built with `--romfs separate`, so it carries
/// only `romfs.id`, and the image stays on the Mac at <work>/extract/<version>/RomFS.img. The launcher puts the image at
/// Documents/games/<title ID>/romfs.img, the first place main.m looks, and a copy of the build's romfs.id beside it once the image is
/// complete. That file is what the next install reads back (devicectl cannot hash a device's file). It is overwritten with a
/// marker before an upload starts, so a cut off upload is never taken for a complete one.
enum GameDataInstall {
    static let idFile = "romfs.id"
    static let imageFile = "romfs.img"
    static let marker = "uploading\n"

    /// `--romfs separate` for an iPhone build, unless the game files go inside the IPA. `separate` is also what keeps the
    /// extraction (`--romfs separate` cannot be combined with `--no-keep-extracted`). An older checkout without the option gets nothing.
    static func romfsArguments(bundled: Bool, supported: Bool) -> [String] {
        guard supported, !bundled else { return [] }
        return ["--romfs", "separate", "--keep-extracted"]
    }

    nonisolated static func repoSupportsRomfsSeparate(_ dir: String) -> Bool {
        guard let text = try? String(contentsOfFile: dir + "/" + BuildModel.buildScript, encoding: .utf8) else { return false }
        return text.contains("'--romfs'") || text.contains("\"--romfs\"")
    }

    /// The extraction's image of a `--romfs separate` build, nil when there is none (an older extraction holds a RomFS folder) or
    /// when the game has DLC: that still goes the earlier way, with the whole game folder copied (#202).
    static func image(inWork work: String) -> String? {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: work + "/aoc"), let v = BuildModel.extractedVersion(in: work + "/extract") else { return nil }
        let image = work + "/extract/" + v + "/RomFS.img"
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: image, isDirectory: &isDir) && !isDir.boolValue ? image : nil
    }

    static func items(image: String) -> [GameDataItem] { [GameDataItem(source: image, destination: imageFile)] }

    static func deviceFolder(titleID: String) -> String { "Documents/games/" + titleID }

    /// "14.7 GB", "820 MB": decimal units, as the issue and the build log say them.
    static func amount(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", max(Double(bytes) / 1e6, 1))
    }

    /// devicectl copy to: a file to a path in the game's folder, or a folder's contents into it (which also makes the folder).
    static func copyToCommand(device: String, bundle: String, source: String, destination: String) -> [String] {
        ["device", "copy", "to", "--device", device, "--source", source, "--destination", destination,
         "--domain-type", "appDataContainer", "--domain-identifier", bundle]
    }

    static func upload(_ item: GameDataItem, xcrun: String, device: String, bundle: String, titleID: String) -> [String] {
        [xcrun, "devicectl"] + copyToCommand(device: device, bundle: bundle, source: item.source, destination: deviceFolder(titleID: titleID) + "/" + item.destination)
    }

    /// devicectl's percent, when it prints one while copying.
    static func uploadStep(_ line: String) -> (detail: String, percent: Double?)? {
        guard let range = line.range(of: #"(\d{1,3})%"#, options: .regularExpression), let n = Double(line[range].dropLast()) else { return nil }
        return ("uploading", min(n, 100))
    }

    /// What the device holds: its romfs.id, read back with devicectl. A failed copy is reported as `problem` only when it says the
    /// device cannot be used (locked, gone), else the file is missing and the image goes up.
    static func readDeviceIdentity(devicectl: DeviceControl, device: String, bundle: String, titleID: String,
                                   scratch: URL = FileManager.default.temporaryDirectory) -> (identity: RomFSIdentity?, problem: (DeviceProblem, String)?) {
        let local = scratch.appendingPathComponent("nxnative-id-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        let r = devicectl.run(["device", "copy", "from", "--device", device, "--source", deviceFolder(titleID: titleID) + "/" + idFile,
                               "--destination", local.path, "--domain-type", "appDataContainer", "--domain-identifier", bundle])
        guard r.ok else {
            let problem = DeviceProblem.of(r.output)
            return (nil, problem == .locked || problem == .noDevice ? (problem, SaveTransfer.lastLine(r.output)) : nil)
        }
        // devicectl may name the file or make a folder of that name around it
        var isDir: ObjCBool = false
        let file = FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir) && isDir.boolValue ? local.appendingPathComponent(idFile) : local
        return ((try? String(contentsOf: file, encoding: .utf8)).flatMap(RomFSIdentity.init), nil)
    }

    /// Writes `text` as the game folder's romfs.id on the device (the marker before an upload, the build's identity after it).
    static func writeDeviceIdentity(_ text: String, devicectl: DeviceControl, device: String, bundle: String, titleID: String,
                                    scratch: URL = FileManager.default.temporaryDirectory) -> (ok: Bool, output: String) {
        let folder = scratch.appendingPathComponent("nxnative-id-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appendingPathComponent(idFile), atomically: true, encoding: .utf8)
        } catch { return (false, error.localizedDescription) }
        return devicectl.run(copyToCommand(device: device, bundle: bundle, source: folder.path, destination: deviceFolder(titleID: titleID)))
    }

    /// The image's identity line, from the repository's own tool (the one that wrote the build's romfs.id).
    static func macIdentity(python: String, repo: String, image: String) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-I", repo + "/" + BuildModel.romfsImageTool, "--identity", image]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

extension BuildModel {
    /// After the slim app is installed: read the three identities, then either say the game data is there or send it, once.
    func installGameData(app: String, bundle: String, device: String, xcrun: String, image: String) {
        let name = deviceName(device), lang = lang
        let tid = Self.titleID(basePath).map { String(format: "%016llX", $0) } ?? "game"
        let python = pythonPath.isEmpty ? "/usr/bin/python3" : pythonPath, repo = repoPath
        let control = DeviceControl.xcrun(xcrun)
        stages.removeAll { $0.id == 1008 }
        stages.append(Stage(id: 1008, name: String(format: t("dev.data.checkStage"), name), state: .running, started: Date()))
        DispatchQueue.global(qos: .userInitiated).async {
            let buildLine = try? String(contentsOfFile: app + "/" + GameDataInstall.idFile, encoding: .utf8)
            let build = buildLine.flatMap(RomFSIdentity.init)
            let mac = GameDataInstall.macIdentity(python: python, repo: repo, image: image).flatMap(RomFSIdentity.init)
            let there = GameDataInstall.readDeviceIdentity(devicectl: control, device: device, bundle: bundle, titleID: tid)
            DispatchQueue.main.async {
                if let i = self.stages.firstIndex(where: { $0.id == 1008 }) { self.stages[i].state = there.problem == nil ? .done : .failed }
                let plan = GameDataPlan.decide(build: build, mac: mac, device: there.identity)
                if let (problem, detail) = there.problem {
                    return self.finishInstall(problem.message(device: name, bytes: mac?.size ?? 0, detail: detail, lang: lang))
                }
                switch plan {
                case .noIdentity, .imageChanged:
                    return self.finishInstall(plan == .imageChanged ? plan.message(device: name, lang: lang) : self.t("dev.data.noIdentity"))
                case .present:
                    self.say(plan.message(device: name, lang: lang))
                    self.installedOn = device; self.installedAppPath = app
                    self.gameDataNote = plan.doneMessage(device: name, lang: lang)
                    self.finishInstall(nil)
                case let .upload(bytes, _, _):
                    self.askTransfer { ok in
                        guard ok else {
                            self.installedOn = device; self.installedAppPath = app
                            self.running = false; self.done = true
                            self.doneNote = String(format: self.t("dev.copySkipped"), name)
                            return
                        }
                        self.uploadGameData(plan: plan, items: GameDataInstall.items(image: image), identity: buildLine ?? "", app: app,
                                            bundle: bundle, device: device, xcrun: xcrun, titleID: tid, bytes: bytes)
                    }
                }
            }
        }
    }

    /// The marker first, then each item, then the identity that says the image is complete.
    private func uploadGameData(plan: GameDataPlan, items: [GameDataItem], identity: String, app: String, bundle: String, device: String,
                                xcrun: String, titleID: String, bytes: Int64) {
        let name = deviceName(device), lang = lang, control = DeviceControl.xcrun(xcrun)
        func fail(_ output: String) {
            finishInstall(DeviceProblem.of(output).message(device: name, bytes: bytes, detail: SaveTransfer.lastLine(output), lang: lang))
        }
        func send(_ rest: [GameDataItem]) {
            guard let item = rest.first else {
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = GameDataInstall.writeDeviceIdentity(identity, devicectl: control, device: device, bundle: bundle, titleID: titleID)
                    DispatchQueue.main.async {
                        guard r.ok else { return fail(r.output) }
                        self.installedOn = device; self.installedAppPath = app
                        self.gameDataNote = plan.doneMessage(device: name, lang: lang)
                        self.finishInstall(nil)
                    }
                }
                return
            }
            runTool(id: 1003, name: plan.message(device: name, lang: lang),
                    GameDataInstall.upload(item, xcrun: xcrun, device: device, bundle: bundle, titleID: titleID), step: GameDataInstall.uploadStep) { error in
                if let error { return fail(error) }
                send(Array(rest.dropFirst()))
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = GameDataInstall.writeDeviceIdentity(GameDataInstall.marker, devicectl: control, device: device, bundle: bundle, titleID: titleID)
            DispatchQueue.main.async {
                guard r.ok else { return fail(r.output) }
                send(items)
            }
        }
    }
}
