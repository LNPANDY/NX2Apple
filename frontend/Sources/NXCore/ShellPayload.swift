import Foundation
import CryptoKit
import PayloadKit

/// The desktop payload route runs only after the installed shell advertises
/// support. It has no shell-build or app-install command, including on failure.
extension ShellInstaller {
    package static let payloadStageID = 1012

    /// nil means the target does not advertise this protocol and needs the
    /// existing first-install/legacy route. A supported shell's errors never
    /// silently fall back to rebuilding and replacing it.
    func installPayloadIfSupported(framework: String, titleID: String, name: String, archive: String) -> Outcome? {
        if cancelled() { return Outcome(ok: false, message: fmt("payload.failed", "cancelled")) }
        let bundle = ShellLibrary.load(root: root).bundleID
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("nx-payload-" + UUID().uuidString)
        do { try fm.createDirectory(at: stage, withIntermediateDirectories: true) }
        catch { return Outcome(ok: false, message: fmt("payload.failed", error.localizedDescription)) }
        defer { try? fm.removeItem(at: stage) }
        let knownHost = payloadHostFile(bundle: bundle)
        let capabilitiesFile = stage.appendingPathComponent(PayloadCapabilities.fileName)
        let readCommand = Self.payloadCopy(xcrun: xcrun, device: device, bundle: bundle, toDevice: false,
                                          source: "Documents/" + PayloadCapabilities.fileName, destination: capabilitiesFile.path)
        let read = runner.capture(ProcessLaunch(executable: readCommand[0], arguments: Array(readCommand.dropFirst()), mergesErrors: true, timeout: 30))
        if cancelled() { return Outcome(ok: false, message: fmt("payload.failed", "cancelled")) }
        guard read.ok, fm.fileExists(atPath: capabilitiesFile.path) else {
            guard fm.fileExists(atPath: knownHost.path) else { return nil }
            // A transient read/lock failure after negotiation must not turn a
            // game update into a shell reinstall. A verified uninstall may use
            // the first-install route again.
            let listing = stage.appendingPathComponent("apps.json")
            let listed = runner.capture(ProcessLaunch(executable: xcrun,
                arguments: ["devicectl"] + InstalledApps.listArguments(device: device, json: listing.path), mergesErrors: true, timeout: 30))
            if listed.ok, let data = try? Data(contentsOf: listing), let apps = InstalledApps.parse(data), !apps.contains(where: { $0.bundle == bundle }) { return nil }
            return Outcome(ok: false, message: t("payload.unavailable"))
        }
        let label = t("payload.stage")
        begin(Self.payloadStageID, label)
        do {
            let capabilities = try JSONDecoder().decode(PayloadCapabilities.self, from: Data(contentsOf: capabilitiesFile))
            guard capabilities.version == PayloadCapabilities.protocolVersion, capabilities.bundleID == bundle,
                  capabilities.teamID == team else { throw PayloadError.incompatible("shell protocol, bundle, or signing team") }
            try fm.createDirectory(at: knownHost.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PayloadArchive.encode(capabilities).write(to: knownHost, options: .atomic)
            let identity = try payloadIdentity(host: capabilities, stage: stage)
            let source = URL(fileURLWithPath: framework)
            let copied = stage.appendingPathComponent(source.lastPathComponent)
            try fm.copyItem(at: source, to: copied)
            // Enumerating first rejects links/special files before codesign.
            let before = try PayloadArchive.fileList(framework: copied, checkCancellation: checkPayloadCancellation)
            var native: [URL] = []
            for file in before {
                let url = stage.appendingPathComponent(file.path)
                if try PayloadNativeCode.isLibrary(url) { native.append(url) }
            }
            guard !native.isEmpty else { throw PayloadError.invalid("no native framework executable") }
            _ = ShellInstall.placeBanner(titleID: titleID, framework: copied.path, banners: banners, picked: pickedArtwork)
            // Sign leaves first. Resource envelopes of nested bundles are not
            // required by dlopen, but every mapped native image must be signed.
            for url in native.sorted(by: { $0.path.count > $1.path.count }) {
                try checkPayloadCancellation()
                let signed = run(["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none", url.path],
                                 env: nil, label: label, step: { _ in nil })
                guard signed.status == 0 else { throw PayloadError.signature(signed.lastError ?? signed.output) }
                let verified = runner.capture(ProcessLaunch(executable: "/usr/bin/codesign", arguments: ["--verify", "--strict", url.path], mergesErrors: true))
                guard verified.ok, try PayloadNativeCode.teamID(url) == capabilities.teamID else {
                    throw PayloadError.signature(verified.out + verified.err)
                }
            }
            let gameData = try Data(contentsOf: copied.appendingPathComponent("game.manifest.json"))
            guard let game = try JSONSerialization.jsonObject(with: gameData) as? [String: Any],
                  game["title_id"] as? String == titleID, game["loader"] as? String == "FH",
                  let executable = game["framework_executable"] as? String,
                  let version = game["display_version"] as? String, let minOS = game["min_os"] as? String else {
                throw PayloadError.invalid("game manifest")
            }
            let manifest = PayloadManifest(titleID: titleID, displayVersion: version, framework: copied.lastPathComponent,
                                           executable: executable, minOS: minOS, teamID: capabilities.teamID,
                                           files: try PayloadArchive.fileList(framework: copied, checkCancellation: checkPayloadCancellation))
            try manifest.compatible(with: capabilities)
            let packed = stage.appendingPathComponent(PayloadArchive.fileName)
            try PayloadArchive.write(manifest: manifest, parent: stage, to: packed, checkCancellation: checkPayloadCancellation)
            let ready = PayloadArchive.Ready(generation: manifest.generation, bytes: try PayloadArchive.size(packed),
                                             sha256: try PayloadArchive.digest(packed, checkCancellation: checkPayloadCancellation), partSize: UInt64(partSize))
            try sendPayload(packed, ready: ready, bundle: bundle, stage: stage, label: label)

            // Query once. A closed/busy shell processes the complete transaction
            // on foreground/return to library. Transfer success is not activation.
            let receiptFile = stage.appendingPathComponent("receipt.json")
            let receiptCommand = Self.payloadCopy(xcrun: xcrun, device: device, bundle: bundle, toDevice: false,
                source: "Documents/" + PayloadStore.receiptsName + "/" + manifest.generation + ".json", destination: receiptFile.path)
            let received = runner.capture(ProcessLaunch(executable: receiptCommand[0], arguments: Array(receiptCommand.dropFirst()), mergesErrors: true, timeout: 30))
            var message = t("payload.awaiting")
            var delivery = PayloadDelivery.awaiting
            if received.ok {
                let receipt = try JSONDecoder().decode(PayloadReceipt.self, from: Data(contentsOf: receiptFile))
                guard receipt.generation == manifest.generation, receipt.titleID == titleID else { throw PayloadError.invalid("receipt identity") }
                switch receipt.state {
                case .active: message = t("payload.active"); delivery = .active
                case .restartRequired: message = t("payload.restart"); delivery = .restartRequired
                case .rejected: throw PayloadError.invalid(receipt.detail)
                }
            }
            // Remember build products for subsequent export/refresh actions,
            // without generating an Xcode project or changing the signed app.
            var library = ShellLibrary.load(root: root)
            library.add(.init(titleID: titleID, name: name, framework: framework))
            try savePayloadLibrary(&library)
            end(Self.payloadStageID, label, ok: true)
            var result = Outcome(ok: true, message: message, appPath: ShellInstall.appPath(root: root), bundleID: bundle)
            result.payloadDelivery = delivery
            let dataFolder = "Documents/" + PayloadStore.gameDataPath(titleID: titleID, generation: manifest.generation)
            if !archive.isEmpty {
                result = copyGameData(titleID: titleID, archive: archive, app: result.appPath, bundleID: bundle,
                                      outcome: result, appJoinsParts: true, dataFolder: dataFolder)
                result.payloadDelivery = delivery
                if result.ok, result.message != message { result.message = message + "\n" + result.message }
            }
            result.payloadDataFolder = dataFolder
            return result
        } catch {
            let detail = String(describing: error)
            log("[RED] payload: \(detail)\n")
            end(Self.payloadStageID, label, ok: false, detail: detail)
            return Outcome(ok: false, message: fmt("payload.failed", detail))
        }
    }

    /// Commit cache mirrors with the library, restoring the previous copies if
    /// its atomic write fails. Successful updates release replaced mirrors.
    func savePayloadLibrary(_ library: inout ShellLibrary) throws {
        ShellInstall.sweepDiscarded(in: ShellInstall.frameworksMirror(root: root))
        let replaced = mirrorFrameworks(&library)
        do { try library.save(root: root) }
        catch {
            for (mirror, previous) in replaced {
                guard ShellInstall.discard(mirror) else {
                    log("library: the previous framework stays at \(previous), its replacement could not be moved away\n")
                    continue
                }
                do { try FileManager.default.moveItem(atPath: previous, toPath: mirror) }
                catch { log("library: the previous framework could not be restored from \(previous): \(error.localizedDescription)\n") }
            }
            throw error
        }
        for (_, previous) in replaced { ShellInstall.discard(previous) }
    }

    /// Select exactly the certificate used by the cached, installed shell.
    /// The executable digest ties that cache to the shell's own handshake.
    func payloadIdentity(host: PayloadCapabilities, stage: URL) throws -> String {
        let app = ShellInstall.appPath(root: root)
        let executable = URL(fileURLWithPath: app).appendingPathComponent(ShellInstall.scheme)
        guard let expected = host.executableSHA256,
              try PayloadArchive.digest(executable, checkCancellation: checkPayloadCancellation) == expected,
              try PayloadNativeCode.teamID(executable) == host.teamID else {
            throw PayloadError.incompatible(t("payload.identityMissing"))
        }
        let prefix = stage.appendingPathComponent("shell-certificate-").path
        // codesign's optional prefix must be attached, otherwise it treats the
        // prefix as another input path instead of an option argument.
        let extracted = runner.capture(ProcessLaunch(executable: "/usr/bin/codesign", arguments: ["-d", "--extract-certificates=" + prefix, app], mergesErrors: true))
        guard extracted.ok, let cert = FileManager.default.contents(atPath: prefix + "0") else {
            throw PayloadError.signature(t("payload.identityMissing"))
        }
        let fingerprint = Insecure.SHA1.hash(data: cert).map { String(format: "%02X", $0) }.joined()
        let identities = runner.capture(ProcessLaunch(executable: "/usr/bin/security", arguments: ["find-identity", "-v", "-p", "codesigning"], mergesErrors: true))
        guard identities.ok, identities.out.uppercased().contains(fingerprint) else { throw PayloadError.signature(t("payload.identityMissing")) }
        return fingerprint
    }

    func sendPayload(_ archive: URL, ready: PayloadArchive.Ready, bundle: String, stage: URL, label: String) throws {
        let destination = "Documents/" + PayloadStore.inboxName + "/" + ready.generation + "/"
        let count = Int((ready.bytes + UInt64(partSize) - 1) / UInt64(partSize))
        var sent: UInt64 = 0
        for index in 0..<count {
            try checkPayloadCancellation()
            let source: URL
            let name: String
            if count == 1 {
                source = archive; name = PayloadArchive.fileName
            } else {
                name = ShellDataParts.name(of: PayloadArchive.fileName, index: index, count: count)
                source = stage.appendingPathComponent(name)
                try ShellDataParts.writePart(source: archive.path, index: index, size: Int64(ready.bytes), partSize: partSize, to: source.path)
            }
            copyProgress(Int64(sent), Int64(ready.bytes))
            let copied = run(Self.payloadCopy(xcrun: xcrun, device: device, bundle: bundle, toDevice: true,
                                              source: source.path, destination: destination + name), env: nil, label: label, step: { _ in nil })
            if count > 1 { try? FileManager.default.removeItem(at: source) }
            guard copied.status == 0 else { throw PayloadError.invalid(copied.lastError ?? copied.output) }
            sent += min(UInt64(partSize), ready.bytes - sent)
        }
        try checkPayloadCancellation()
        let marker = stage.appendingPathComponent(PayloadArchive.readyName)
        try PayloadArchive.encode(ready).write(to: marker)
        let committed = run(Self.payloadCopy(xcrun: xcrun, device: device, bundle: bundle, toDevice: true,
                                             source: marker.path, destination: destination + PayloadArchive.readyName),
                            env: nil, label: label, step: { _ in nil })
        guard committed.status == 0 else { throw PayloadError.invalid(committed.lastError ?? committed.output) }
        copyProgress(Int64(ready.bytes), Int64(ready.bytes))
    }

    package static func payloadCopy(xcrun: String, device: String, bundle: String, toDevice: Bool, source: String, destination: String) -> [String] {
        [xcrun, "devicectl", "device", "copy", toDevice ? "to" : "from", "--device", device,
         "--domain-type", "appDataContainer", "--domain-identifier", bundle,
         "--source", source, "--destination", destination]
    }

    func payloadHostFile(bundle: String) -> URL {
        let key = SHA256.hash(data: Data((device + "\0" + bundle).utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: root).appendingPathComponent("payload-hosts/" + key + ".json")
    }

    func checkPayloadCancellation() throws {
        if cancelled() { throw PayloadError.invalid("cancelled") }
    }
}
