import Foundation

// Fast hot-framework delivery for an already-installed shared app (#1165, zero engine patches):
// When `DmShell.app` is already on the device under the same signing team (`Documents/.shell-host.json`), its provisioning
// profile has at least 24 hours left, this Mac holds the matching `Apple Development` signing identity, and every new
// `DmGame<ID>.framework` carries its own host (`loader == "FH"`), the launcher signs the framework bundle directly with
// `codesign` and copies it to `Documents/Frameworks/.staging-<ID>-<token>/DmGame<ID>.framework` followed by `.ready`.
// Any missing prerequisite or transfer error falls back cleanly to the full `xcodebuild` + `devicectl device install app` flow.

package enum ShellHotInstall {
    package static let beaconRemotePath = "Documents/.shell-host.json"
    package static let glueVersion = 1
    /// Fall back to full `xcodebuild` when fewer than 24 hours remain on a 7-day profile so the app's signature is renewed too.
    package static let minRemainingLifetime: Int64 = 24 * 3600

    package struct HostBeacon: Codable, Equatable {
        package var schema: Int
        package var glueVersion: Int
        package var bundleID: String
        package var teamID: String
        package var chain: String
        package var version: String
        package var expiresAtEpoch: Int64?

        package init(schema: Int = 1, glueVersion: Int = ShellHotInstall.glueVersion, bundleID: String, teamID: String,
                     chain: String, version: String, expiresAtEpoch: Int64? = nil) {
            self.schema = schema
            self.glueVersion = glueVersion
            self.bundleID = bundleID
            self.teamID = teamID
            self.chain = chain
            self.version = version
            self.expiresAtEpoch = expiresAtEpoch
        }
    }

    package struct ReadyMarker: Codable, Equatable {
        package var schema: Int
        package var titleID: String
        package var files: Int
        package var bytes: Int64

        package init(schema: Int = 1, titleID: String, files: Int, bytes: Int64) {
            self.schema = schema
            self.titleID = titleID
            self.files = files
            self.bytes = bytes
        }
    }

    package enum BeaconVerdict: Equatable {
        case eligible(HostBeacon)
        case unreadable
        case incompatible(String)
        case expiringSoon
    }

    package static func defaultSigningIdentity(team: String, runner: ProcessRunner) -> String? {
        guard !team.isEmpty else { return nil }
        return DeviceTools.certificateTeams(runner: runner).first { $0.id == team && !$0.identity.isEmpty }?.identity
    }

    /// True when `<framework>/game.manifest.json` declares `loader == "FH"` and its executable exists on disk.
    package static func supportsHotPush(framework: String, titleID: String = "", fm: FileManager = .default) -> Bool {
        guard let data = fm.contents(atPath: framework + "/game.manifest.json"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json["loader"] as? String) == "FH" else { return false }
        let fallbackID = titleID.isEmpty ? ShellInstall.titleID(ofFramework: framework) : titleID
        let exe = (json["framework_executable"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "DmGame\(fallbackID)"
        return !exe.isEmpty && fm.fileExists(atPath: framework + "/" + exe)
    }

    package static func evaluateBeacon(_ data: Data?, expectedBundleID: String, team: String, nowEpoch: Int64) -> BeaconVerdict {
        guard let data, let beacon = try? JSONDecoder().decode(HostBeacon.self, from: data) else {
            return .unreadable
        }
        guard beacon.schema == 1, beacon.glueVersion == glueVersion else {
            return .incompatible("glue \(beacon.glueVersion)")
        }
        guard !expectedBundleID.isEmpty, beacon.bundleID == expectedBundleID else {
            return .incompatible("bundleID \(beacon.bundleID)")
        }
        guard !team.isEmpty, beacon.teamID == team else {
            return .incompatible("teamID \(beacon.teamID.isEmpty ? "none" : beacon.teamID)")
        }
        if let exp = beacon.expiresAtEpoch, exp - nowEpoch < minRemainingLifetime {
            return .expiringSoon
        }
        return .eligible(beacon)
    }

    /// Counts regular files and total bytes inside a signed framework directory, matching `GameCatalogue.frameworkFootprint` on iOS.
    package static func frameworkFootprint(atPath path: String, fm: FileManager = .default) -> (files: Int, bytes: Int64)? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              let enumerator = fm.enumerator(atPath: path) else { return nil }
        var files = 0
        var bytes: Int64 = 0
        for case let rel as String in enumerator {
            let name = (rel as NSString).lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") { continue }
            let full = path + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let type = attrs[.type] as? FileAttributeType else { return nil }
            if type == .typeDirectory { continue }
            guard type == .typeRegular, let size = (attrs[.size] as? NSNumber)?.int64Value, size >= 0 else { return nil }
            if Int64.max - bytes < size { return nil }
            files += 1
            bytes += size
        }
        return (files, bytes)
    }

    package static func beaconCommand(xcrun: String, device: String, bundleID: String, destination: String) -> [String] {
        [xcrun, "devicectl", "device", "copy", "from", "--device", device, "--domain-type", "appDataContainer",
         "--domain-identifier", bundleID, "--source", beaconRemotePath, "--destination", destination]
    }

    package static func cleanFrameworkAttributesCommand(framework: String) -> [String] {
        ["/usr/bin/xattr", "-cr", framework]
    }

    package static func codesignFrameworkCommand(codesign: String = "/usr/bin/codesign", identity: String, framework: String) -> [String] {
        [codesign, "--force", "--sign", identity, "--timestamp=none", framework]
    }

    package static func copyFrameworkCommand(xcrun: String, device: String, bundleID: String,
                                             sourceFramework: String, stagingSubdir: String, frameworkName: String) -> [String] {
        [xcrun, "devicectl", "device", "copy", "to", "--device", device, "--source", sourceFramework,
         "--destination", stagingSubdir + "/" + frameworkName,
         "--domain-type", "appDataContainer", "--domain-identifier", bundleID]
    }

    package static func copyReadyCommand(xcrun: String, device: String, bundleID: String,
                                         sourceReady: String, stagingSubdir: String) -> [String] {
        [xcrun, "devicectl", "device", "copy", "to", "--device", device, "--source", sourceReady,
         "--destination", stagingSubdir + "/.ready",
         "--domain-type", "appDataContainer", "--domain-identifier", bundleID]
    }
}

extension ShellInstaller {
    package struct HotGame {
        package var framework: String
        package var titleID: String
        package var name: String
        package var pickedArtwork: String?
    }

    /// Attempts a ~2-second hot framework sign + push into `Documents/Frameworks/` when the shared app is already installed on
    /// `device` with the same team and valid provisioning lifetime. Returns nil whenever full `xcodebuild` should run instead.
    func tryHotInstall(games: [HotGame]) -> (outcome: Outcome, notes: [String])? {
        let fm = FileManager.default
        guard !games.isEmpty, !team.isEmpty, !device.isEmpty else { return nil }
        guard games.allSatisfy({ ShellHotInstall.supportsHotPush(framework: $0.framework, titleID: $0.titleID, fm: fm) }) else {
            return nil
        }
        let stateFile = ShellLibrary.stateFile(root: root)
        guard fm.fileExists(atPath: stateFile) else { return nil }
        let existing = ShellLibrary.load(root: root)
        guard !existing.bundleID.isEmpty else { return nil }
        guard let identity = signingIdentity(team, runner), !identity.isEmpty else {
            log("hot-install: no local development certificate for team \(team), using full app build\n")
            return nil
        }
        if let refused = pairingRefusal() { return (refused, []) }

        let beaconFile = NSTemporaryDirectory() + "nspb-shell-beacon-\(UUID().uuidString.prefix(8)).json"
        defer { try? fm.removeItem(atPath: beaconFile) }
        let fetched = run(ShellHotInstall.beaconCommand(xcrun: xcrun, device: device, bundleID: existing.bundleID, destination: beaconFile),
                          env: nil, label: "hot-check", step: { _ in nil })
        let beaconData = fetched.status == 0 ? fm.contents(atPath: beaconFile) : nil
        switch ShellHotInstall.evaluateBeacon(beaconData, expectedBundleID: existing.bundleID,
                                              team: team, nowEpoch: Int64(now().timeIntervalSince1970)) {
        case .eligible:
            break
        case .unreadable:
            log("hot-install: shared app host beacon not present on device, using full app build\n")
            return nil
        case .incompatible(let detail):
            log("hot-install: host beacon mismatch (\(detail)), using full app build\n")
            return nil
        case .expiringSoon:
            log("hot-install: device provisioning profile expires within 24 hours, using full app build to renew signature\n")
            return nil
        }

        ShellInstall.sweepDiscarded(in: ShellInstall.frameworksMirror(root: root))
        let before = fm.contents(atPath: stateFile)
        var replaced: [(mirror: String, previous: String)] = []
        func rollback() {
            if let before { try? before.write(to: URL(fileURLWithPath: stateFile), options: .atomic) }
            else if fm.fileExists(atPath: stateFile) { try? fm.removeItem(atPath: stateFile) }
            for (mirror, previous) in replaced {
                guard ShellInstall.discard(mirror) else { continue }
                try? fm.moveItem(atPath: previous, toPath: mirror)
            }
        }

        var library = existing
        library.team = team
        for game in games {
            library.add(.init(titleID: game.titleID, name: game.name, framework: game.framework))
        }
        replaced = mirrorFrameworks(&library)
        library.dropMissing()
        var notes: [String] = []
        for game in games {
            let checked = leaveOutIncomplete(&library, titleID: game.titleID, name: game.name)
            if checked.failure != nil {
                rollback()
                return nil
            }
            notes.append(contentsOf: checked.notes)
        }
        let pickedByID = Dictionary(uniqueKeysWithValues: games.map { ($0.titleID.uppercased(), $0.pickedArtwork) })
        for game in library.games {
            let picked = pickedByID[game.titleID.uppercased()] ?? nil
            _ = ShellInstall.placeBanner(titleID: game.titleID, framework: game.framework, banners: banners, picked: picked)
        }

        let stageDir = NSTemporaryDirectory() + "nspb-hot-fw-\(UUID().uuidString.prefix(8))"
        defer { try? fm.removeItem(atPath: stageDir) }
        do {
            try fm.createDirectory(atPath: stageDir, withIntermediateDirectories: true)
        } catch {
            rollback()
            return nil
        }

        let installName = fmt("dev.installStage", deviceName)
        begin(Self.installStageID, installName)

        for (idx, game) in games.enumerated() {
            let upperID = game.titleID.uppercased()
            let sourceFW = library.games.first { $0.titleID.caseInsensitiveCompare(game.titleID) == .orderedSame }?.framework ?? game.framework
            let fwName = (sourceFW as NSString).lastPathComponent
            let localCopy = stageDir + "/\(idx)-" + fwName
            do {
                try fm.copyItem(atPath: sourceFW, toPath: localCopy)
            } catch {
                log("hot-install: could not stage \(fwName): \(error.localizedDescription), falling back to full app build\n")
                rollback()
                return nil
            }
            _ = run(ShellHotInstall.cleanFrameworkAttributesCommand(framework: localCopy), env: nil, label: installName, step: { _ in nil })
            let signed = run(ShellHotInstall.codesignFrameworkCommand(codesign: codesignPath, identity: identity, framework: localCopy),
                             env: nil, label: installName, step: { _ in nil })
            guard signed.status == 0,
                  let footprint = ShellHotInstall.frameworkFootprint(atPath: localCopy, fm: fm) else {
                log("hot-install: codesign failed for \(fwName), falling back to full app build\n")
                rollback()
                return nil
            }
            let token = UUID().uuidString.prefix(8).lowercased()
            let remoteStaging = "Documents/Frameworks/.staging-\(upperID)-\(token)"
            let copiedFW = run(ShellHotInstall.copyFrameworkCommand(xcrun: xcrun, device: device, bundleID: library.bundleID,
                                                                    sourceFramework: localCopy, stagingSubdir: remoteStaging,
                                                                    frameworkName: fwName),
                               env: nil, label: installName, stageID: Self.installStageID, step: BuildProgress.installStep)
            guard copiedFW.status == 0 else {
                log("hot-install: copying \(fwName) failed, falling back to full app build\n")
                rollback()
                return nil
            }
            let ready = ShellHotInstall.ReadyMarker(titleID: upperID, files: footprint.files, bytes: footprint.bytes)
            let readyLocal = stageDir + "/\(idx)-.ready"
            guard let readyData = try? JSONEncoder().encode(ready),
                  (try? readyData.write(to: URL(fileURLWithPath: readyLocal), options: .atomic)) != nil else {
                rollback()
                return nil
            }
            let copiedReady = run(ShellHotInstall.copyReadyCommand(xcrun: xcrun, device: device, bundleID: library.bundleID,
                                                                   sourceReady: readyLocal, stagingSubdir: remoteStaging),
                                  env: nil, label: installName, step: { _ in nil })
            guard copiedReady.status == 0 else {
                log("hot-install: writing .ready for \(fwName) failed, falling back to full app build\n")
                rollback()
                return nil
            }
        }

        do {
            try library.save(root: root)
        } catch {
            rollback()
            return nil
        }
        for (_, previous) in replaced { ShellInstall.discard(previous) }
        ShellLibrary.recordInstalled(root: root)
        end(Self.installStageID, installName, ok: true)
        let outcome = Outcome(ok: true, message: fmt("dev.installed", deviceName),
                              appPath: ShellInstall.appPath(root: root), bundleID: library.bundleID)
        return (outcome, notes)
    }
}
