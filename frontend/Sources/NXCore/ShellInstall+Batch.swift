import Foundation

// Installing built frameworks without rebuilding any game, and installing a queued batch of built frameworks once at the end.

extension ShellInstaller {
    /// One game of a queued shared-app install batch.
    package struct BatchGame: Equatable {
        package var framework: String
        package var titleID: String
        package var name: String
        package var archive: String
        package var pickedArtwork: String?

        package init(framework: String, titleID: String, name: String, archive: String, pickedArtwork: String? = nil) {
            self.framework = framework
            self.titleID = titleID
            self.name = name
            self.archive = archive
            self.pickedArtwork = pickedArtwork
        }
    }

    /// Signs and installs the shared app from the frameworks already built in `shell.json`, without rebuilding any game or
    /// transferring `romfs.img` game data.
    package func installBuilt(framework: String, titleID: String, name: String) -> Outcome {
        let signed = signAndInstallApp(framework: framework, titleID: titleID, name: name)
        guard signed.outcome.ok else { return signed.outcome }
        var outcome = signed.outcome
        if !signed.notes.isEmpty {
            outcome.message = ([outcome.message] + signed.notes).joined(separator: "\n")
        }
        return outcome
    }

    /// Signs and installs the shared app once for all games built in a queue batch, then copies the missing game data of each game.
    package func installBatch(_ games: [BatchGame]) -> Outcome {
        guard let last = games.last else {
            return Outcome(ok: false, message: fmt("shell.projectFailed", "empty batch"))
        }
        if games.count == 1 {
            var single = self
            single.pickedArtwork = last.pickedArtwork
            return single.install(framework: last.framework, titleID: last.titleID, name: last.name, archive: last.archive)
        }
        let fm = FileManager.default
        for game in games where !fm.fileExists(atPath: game.framework) {
            return missingFramework(game.framework, name: game.name)
        }
        if let hot = tryHotInstall(games: games.map {
            HotGame(framework: $0.framework, titleID: $0.titleID, name: $0.name, pickedArtwork: $0.pickedArtwork)
        }) {
            guard hot.outcome.ok else { return hot.outcome }
            var result = copyBatchGameData(games, app: hot.outcome.appPath, bundleID: hot.outcome.bundleID, start: hot.outcome)
            if result.ok, !hot.notes.isEmpty {
                result.message = ([result.message] + hot.notes).joined(separator: "\n")
            }
            return result
        }
        if let refused = pairingRefusal() { return refused }

        let stateFile = ShellLibrary.stateFile(root: root)
        let before = fm.contents(atPath: stateFile)
        var library = ShellLibrary.load(root: root)
        for game in games.dropLast() {
            library.add(.init(titleID: game.titleID, name: game.name, framework: game.framework))
            if let picked = game.pickedArtwork {
                _ = ShellInstall.placeBanner(titleID: game.titleID, framework: game.framework, banners: banners, picked: picked)
            }
        }
        do {
            try library.save(root: root)
        } catch {
            return Outcome(ok: false, message: fmt("shell.projectFailed", error.localizedDescription))
        }

        var batchInstaller = self
        batchInstaller.pickedArtwork = last.pickedArtwork
        let signed = batchInstaller.signAndInstallApp(framework: last.framework, titleID: last.titleID, name: last.name)
        guard signed.outcome.ok else {
            if let before { try? before.write(to: URL(fileURLWithPath: stateFile), options: .atomic) }
            else if fm.fileExists(atPath: stateFile) { try? fm.removeItem(atPath: stateFile) }
            return signed.outcome
        }
        // Re-apply picked artwork for earlier games in the batch on the mirrored frameworks inside the built app if needed
        let mirrored = ShellLibrary.load(root: root)
        for game in games.dropLast() {
            if let picked = game.pickedArtwork,
               let entry = mirrored.games.first(where: { $0.titleID.caseInsensitiveCompare(game.titleID) == .orderedSame }) {
                _ = ShellInstall.placeBanner(titleID: entry.titleID, framework: entry.framework, banners: banners, picked: picked)
            }
        }

        var result = copyBatchGameData(games, app: signed.outcome.appPath, bundleID: signed.outcome.bundleID, start: signed.outcome)
        if result.ok, !signed.notes.isEmpty {
            result.message = ([result.message] + signed.notes).joined(separator: "\n")
        }
        return result
    }

    /// Retries only the game-data transfer step for a batch install whose app bundle is already on the device.
    package func installBatchData(_ games: [BatchGame]) -> Outcome {
        if let refused = pairingRefusal() { return refused }
        let bundleID = ShellLibrary.load(root: root).bundleID
        let app = ShellInstall.appPath(root: root)
        let start = Outcome(ok: true, message: fmt("dev.installed", deviceName), appPath: app, bundleID: bundleID)
        return copyBatchGameData(games, app: app, bundleID: bundleID, start: start)
    }

    private struct PendingGameCopy {
        var game: BatchGame
        var local: [String: Int64]
        var missing: [ShellDataParts.Item]
        var needed: Int64
        var receipt: String
        var partsReceipt: String
        var previous: String?
        var identity: String?
    }

    private func copyBatchGameData(_ games: [BatchGame], app: String, bundleID: String, start: Outcome) -> Outcome {
        var outcome = start
        let checkName = fmt("shell.checkStage", deviceName)
        begin(Self.checkStageID, checkName)
        var pending: [PendingGameCopy] = []
        var totalNeeded: Int64 = 0
        var totalFiles = 0
        var anyVersionChanged = false
        var allCurrent = true

        for game in games where !game.archive.isEmpty {
            let listing = NSTemporaryDirectory() + "nspb-shell-files-\(UUID().uuidString.prefix(8)).json"
            defer { try? FileManager.default.removeItem(atPath: listing) }
            _ = run(ShellInstall.listCommand(xcrun: xcrun, device: device, bundleID: bundleID, titleID: game.titleID, json: listing),
                    env: nil, label: checkName, step: { _ in nil })
            let onDevice = ShellInstall.parseListing(FileManager.default.contents(atPath: listing))
            let local = ShellInstall.localFiles(in: game.archive)
            let receipt = "shellCopiedRomFS/\(device)/\(bundleID)/\(game.titleID)"
            let previous = defaults.string(forKey: receipt)
            let identity = local["romfs.img"] == nil ? nil : imageIdentity(archive: game.archive, titleID: game.titleID)
            let partsReceipt = receipt + "/parts"
            var comparable = onDevice
            if identity != previous {
                allCurrent = false
                comparable.removeValue(forKey: "romfs.img")
                if identity == nil || defaults.string(forKey: partsReceipt) != identity {
                    comparable = comparable.filter { !ShellDataParts.isPart($0.key, of: "romfs.img") }
                }
            } else if identity == nil {
                allCurrent = false
            }
            let missing = ShellDataParts.toCopy(local: local, device: comparable, splitAbove: partSize, partSize: partSize)
            guard !missing.isEmpty else { continue }
            let needed = missing.reduce(Int64(0)) { sum, item in
                let b = ShellDataParts.bytes(of: item, local: local, partSize: partSize)
                return Int64.max - sum < b ? Int64.max : sum + b
            }
            totalNeeded = Int64.max - totalNeeded < needed ? Int64.max : totalNeeded + needed
            totalFiles += Set(missing.map(\.file)).count
            if let identity, let previous, identity != previous { anyVersionChanged = true }
            pending.append(PendingGameCopy(game: game, local: local, missing: missing, needed: needed,
                                           receipt: receipt, partsReceipt: partsReceipt, previous: previous, identity: identity))
        }
        end(Self.checkStageID, checkName, ok: true)

        guard !pending.isEmpty else {
            outcome.message = fmt(allCurrent ? "shell.dataCurrent" : "shell.dataAlready", deviceName)
            return outcome
        }

        let logCopy = NSTemporaryDirectory() + "nspb-shell-log-\(UUID().uuidString.prefix(8)).txt"
        defer { try? FileManager.default.removeItem(atPath: logCopy) }
        _ = run(ShellInstall.shellLogCommand(xcrun: xcrun, device: device, bundleID: bundleID, destination: logCopy),
                env: nil, label: checkName, step: { _ in nil })
        if let free = ShellInstall.freeSpace(inShellLog: try? String(contentsOfFile: logCopy, encoding: .utf8)) {
            log("device free space: \(free) bytes, the batch game data to copy: \(totalNeeded) bytes\n")
            if free - ShellInstall.freeSpaceMargin < totalNeeded {
                return Outcome(ok: false, message: fmt("shell.noSpace", deviceName, Double(totalNeeded) / 1e9, Double(free) / 1e9),
                               appPath: app, bundleID: bundleID)
            }
        }

        var link = connection()
        var plan = copyPlan(files: totalFiles, bytes: totalNeeded, connection: link)
        if anyVersionChanged {
            let note = t("shell.dataChanged")
            plan.versionNote = note
            log(note + "\n")
        }
        log(plan.sizeText + "\n" + plan.connectionText + "\n")
        let parts = pending.reduce(0) { $0 + $1.missing.filter { if case .part = $0 { return true } else { return false } }.count }
        if parts > 0 { log(fmt("shell.dataParts", parts) + "\n") }
        var decision = decideCopy(plan)
        if decision == .waitForCable {
            log(fmt("shell.copyWaiting", deviceName) + "\n")
            waiting(true)
            while !waitCancelled() {
                Thread.sleep(forTimeInterval: pollInterval)
                link = connection()
                if link == .wired { break }
            }
            waiting(false)
            decision = link == .wired && !waitCancelled() ? .copy : .skip
        }
        guard decision == .copy else {
            outcome.copySkipped = true
            outcome.message = fmt("dev.copySkipped", deviceName)
            return outcome
        }

        let copyName = fmt("dev.copyStage", deviceName)
        begin(Self.copyStageID, copyName)
        let totalItems = pending.reduce(0) { $0 + $1.missing.count }
        var copiedItems = 0
        var copiedBytes: Int64 = 0

        for entry in pending {
            for item in entry.missing {
                if waitCancelled() {
                    end(Self.copyStageID, copyName, ok: false, detail: "")
                    outcome.copySkipped = true
                    outcome.message = fmt("dev.copySkipped", deviceName)
                    return outcome
                }
                copyProgress(copiedBytes, totalNeeded)
                let itemDetail = "\(copiedItems + 1)/\(totalItems)"
                stage(ShellStage(id: Self.copyStageID, name: copyName, state: .running, detail: itemDetail,
                                 percent: copiedBytes > 0 && totalNeeded > 0 ? Double(copiedBytes) / Double(totalNeeded) * 100 : nil))
                if item.file == "romfs.img", entry.previous != nil { defaults.removeObject(forKey: entry.receipt) }
                var source = entry.game.archive + "/" + item.file, destination = item.file, staged: String?
                if case .part(let file, let index, let count) = item {
                    if file == "romfs.img", let identity = entry.identity { defaults.set(identity, forKey: entry.partsReceipt) }
                    let path = NSTemporaryDirectory() + "nspb-part-\(UUID().uuidString.prefix(8))"
                    do {
                        try ShellDataParts.writePart(source: source, index: index, size: entry.local[file] ?? 0, partSize: partSize, to: path)
                    } catch {
                        try? FileManager.default.removeItem(atPath: path)
                        let why = error.localizedDescription
                        end(Self.copyStageID, copyName, ok: false, detail: why)
                        var incomplete = Outcome(ok: false, message: fmt("shell.copyIncomplete", deviceName, why), appPath: app,
                                                 bundleID: bundleID, copied: copiedItems, failure: .shellDataIncomplete)
                        incomplete.detail = why
                        return incomplete
                    }
                    staged = path; source = path; destination = ShellDataParts.name(of: file, index: index, count: count)
                }
                let finishedBytes = copiedBytes
                let itemBytes = ShellDataParts.bytes(of: item, local: entry.local, partSize: partSize)
                let r = run(ShellInstall.copyCommand(xcrun: xcrun, device: device, bundleID: bundleID, titleID: entry.game.titleID,
                                                     source: source, relativePath: destination),
                            env: nil, label: copyName, stageID: Self.copyStageID) { line in
                    guard let parsed = BuildProgress.installStep(line), let raw = parsed.percent else { return nil }
                    let clamped = min(max(raw, 0), 100)
                    guard totalNeeded > 0 else { return (itemDetail, clamped > 0 ? clamped : nil) }
                    let doneBytes = Double(finishedBytes) + Double(itemBytes) * clamped / 100.0
                    copyProgress(min(Int64(doneBytes.rounded()), totalNeeded), totalNeeded)
                    let weighted = min(doneBytes / Double(totalNeeded) * 100.0, 100.0)
                    return (itemDetail, weighted > 0 ? weighted : nil)
                }
                if let staged { try? FileManager.default.removeItem(atPath: staged) }
                if r.status != 0 {
                    let why = r.lastError ?? fmt("msg.exitCode", r.status)
                    end(Self.copyStageID, copyName, ok: false, detail: why)
                    var incomplete = Outcome(ok: false, message: fmt("shell.copyIncomplete", deviceName, why), appPath: app,
                                             bundleID: bundleID, copied: copiedItems, failure: .shellDataIncomplete)
                    incomplete.detail = why
                    return incomplete
                }
                copiedItems += 1
                outcome.copied = copiedItems
                copiedBytes += itemBytes
            }
            if let identity = entry.identity, entry.missing.contains(where: { $0.file == "romfs.img" }) {
                defaults.set(identity, forKey: entry.receipt)
                defaults.removeObject(forKey: entry.partsReceipt)
            }
        }
        copyProgress(totalNeeded, totalNeeded)
        end(Self.copyStageID, copyName, ok: true)
        return outcome
    }
}
