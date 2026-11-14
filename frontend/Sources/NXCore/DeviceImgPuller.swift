import Foundation

extension ShellInstall {
    /// Default bundle identifier of the shared iOS shell app container.
    package static let bundleID = ShellLibrary.defaultBundleID
}

/// Errors reported while pulling an existing RomFS `.img` from a paired iPhone or iPad.
package enum DeviceImgPullError: LocalizedError, Equatable, Sendable {
    case missingDevice
    case imageNotFoundOnDevice
    case transferFailed(String)
    case invalidPulledImage
    case cancelled

    package var errorDescription: String? {
        switch self {
        case .missingDevice:
            return "No device selected"
        case .imageNotFoundOnDevice:
            return "Game image not found on device"
        case .transferFailed(let detail):
            return detail.isEmpty ? "Device file transfer failed" : detail
        case .invalidPulledImage:
            return "Pulled image is corrupt or does not match expected game identity"
        case .cancelled:
            return "Cancelled"
        }
    }
}

/// Pulls a game's primary RomFS `.img` out of the shared shell container on a paired iOS device into `<outDir>/games/<FolderName>/`.
package struct DeviceImgPuller: @unchecked Sendable {
    package var control: DeviceControl

    package init(control: DeviceControl) {
        self.control = control
    }

    /// `devicectl` arguments for listing `Documents/games/<titleID>`, derived from `ShellInstall.listCommand`.
    package static func listFilesArguments(
        device: String,
        bundleID: String,
        titleID: String,
        jsonPath: String
    ) -> [String] {
        let full = ShellInstall.listCommand(
            xcrun: "/usr/bin/xcrun",
            device: device,
            bundleID: bundleID,
            titleID: titleID,
            json: jsonPath
        )
        return Array(full.dropFirst(2))
    }

    /// `devicectl` arguments for copying one remote container file to a local destination, matching `SaveTransfer.copyFromCommand`.
    package static func copyFromArguments(
        device: String,
        bundleID: String,
        source: String,
        destination: String
    ) -> [String] {
        [
            "device", "copy", "from",
            "--device", device,
            "--source", source,
            "--destination", destination,
            "--domain-type", "appDataContainer",
            "--domain-identifier", bundleID,
        ]
    }

    /// Pulls the game's `.img` from `Documents/games/<titleID>`, verifies its `DMROMFS1` integrity and optional identity line,
    /// and atomically places it into `<outDir>/games/<ArchiveDir>/<PrimaryImgName>`.
    package func pullImage(
        device: String,
        bundleID: String = ShellInstall.bundleID,
        titleID: String,
        gameName: String,
        outDir: String,
        expectedIdentity: String? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> Result<String, DeviceImgPullError> {
        if isCancelled() {
            return .failure(.cancelled)
        }
        let trimmedDevice = device.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDevice.isEmpty else {
            return .failure(.missingDevice)
        }
        let rawTID = titleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTID.isEmpty else {
            return .failure(.imageNotFoundOnDevice)
        }
        let tid = rawTID.uppercased()
        let trimmedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBundleID = trimmedBundle.isEmpty ? ShellInstall.bundleID : trimmedBundle
        let baseOutDir = outDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseOutDir.isEmpty else {
            return .failure(.transferFailed("Output directory is empty"))
        }

        let fm = FileManager.default
        let cleanedName = RomFSArchive.cleanPackageGameName(gameName)
        let effectiveGameName = cleanedName.isEmpty ? gameName : cleanedName
        let sanitizedHint = RomFSArchive.sanitizeGameName(effectiveGameName, fallback: tid)

        guard let resolvedRemote = findRemoteImage(
            device: trimmedDevice,
            bundleID: effectiveBundleID,
            primaryTID: tid,
            fallbackTID: rawTID,
            folderHint: sanitizedHint,
            fm: fm,
            isCancelled: isCancelled
        ) else {
            return isCancelled() ? .failure(.cancelled) : .failure(.imageNotFoundOnDevice)
        }
        switch resolvedRemote {
        case .failure(let err):
            return .failure(err)
        case .success(let remote):
            return transferAndCommit(
                device: trimmedDevice,
                bundleID: effectiveBundleID,
                canonicalTID: tid,
                remoteTID: remote.dirTID,
                remoteImg: remote.fileName,
                effectiveGameName: effectiveGameName,
                baseOutDir: baseOutDir,
                expectedIdentity: expectedIdentity,
                fm: fm,
                isCancelled: isCancelled
            )
        }
    }

    private func findRemoteImage(
        device: String,
        bundleID: String,
        primaryTID: String,
        fallbackTID: String,
        folderHint: String,
        fm: FileManager,
        isCancelled: @Sendable () -> Bool
    ) -> Result<(dirTID: String, fileName: String), DeviceImgPullError>? {
        var candidateTIDs = [primaryTID]
        if fallbackTID != primaryTID {
            candidateTIDs.append(fallbackTID)
        }
        for candidateTID in candidateTIDs {
            if isCancelled() {
                return .failure(.cancelled)
            }
            let listJsonURL = fm.temporaryDirectory.appendingPathComponent("nspb-pull-list-\(UUID().uuidString).json")
            defer { try? fm.removeItem(at: listJsonURL) }
            let listRes = control.run(
                Self.listFilesArguments(
                    device: device,
                    bundleID: bundleID,
                    titleID: candidateTID,
                    jsonPath: listJsonURL.path
                )
            )
            if isCancelled() {
                return .failure(.cancelled)
            }
            if !listRes.ok && !fm.fileExists(atPath: listJsonURL.path) {
                if listRes.output.contains(DeviceControl.timedOut) || listRes.output.lowercased().contains("timed out") {
                    return .failure(.transferFailed(DeviceControl.timedOut))
                }
            }
            let onDevice = ShellInstall.parseListing(fm.contents(atPath: listJsonURL.path))
            if let remoteName = Self.selectRemoteImageName(from: onDevice, folderHint: folderHint) {
                return .success((dirTID: candidateTID, fileName: remoteName))
            }
        }
        return nil
    }

    private func transferAndCommit(
        device: String,
        bundleID: String,
        canonicalTID: String,
        remoteTID: String,
        remoteImg: String,
        effectiveGameName: String,
        baseOutDir: String,
        expectedIdentity: String?,
        fm: FileManager,
        isCancelled: @Sendable () -> Bool
    ) -> Result<String, DeviceImgPullError> {
        let gamesRoot = (baseOutDir as NSString).appendingPathComponent("games")
        let folderName = RomFSArchive.archiveDirectoryName(
            gameName: effectiveGameName,
            titleID: canonicalTID,
            gamesRoot: gamesRoot,
            fm: fm
        )
        let destDir = (gamesRoot as NSString).appendingPathComponent(folderName)
        do {
            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        } catch {
            return .failure(.transferFailed(error.localizedDescription))
        }

        let tempDest = (destDir as NSString).appendingPathComponent(".\(UUID().uuidString).pull.tmp")
        var committed = false
        defer {
            if !committed {
                try? fm.removeItem(atPath: tempDest)
            } else if fm.fileExists(atPath: tempDest) {
                try? fm.removeItem(atPath: tempDest)
            }
        }

        if isCancelled() {
            return .failure(.cancelled)
        }

        let remoteSource = ShellInstall.gameFolder(titleID: remoteTID) + "/" + remoteImg
        let copyRes = control.run(
            Self.copyFromArguments(
                device: device,
                bundleID: bundleID,
                source: remoteSource,
                destination: tempDest
            )
        )
        if isCancelled() {
            return .failure(.cancelled)
        }
        guard copyRes.ok else {
            return .failure(.transferFailed(Self.cleanErrorLine(copyRes.output)))
        }

        guard let pulledFilePath = Self.locatePulledFile(tempDest: tempDest, remoteImg: remoteImg, fm: fm) else {
            return .failure(.invalidPulledImage)
        }

        if let expected = expectedIdentity?.trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty {
            guard RomfsImageIdentity.matches(imagePath: pulledFilePath, expectedIdentityLine: expected) else {
                return .failure(.invalidPulledImage)
            }
        } else {
            guard RomfsImageIdentity.computeIdentity(of: pulledFilePath) != nil else {
                return .failure(.invalidPulledImage)
            }
        }

        if isCancelled() {
            return .failure(.cancelled)
        }

        let primaryImageName = RomFSArchive.primaryImageName(in: destDir, fm: fm) ?? (folderName + ".img")
        let finalImgPath = (destDir as NSString).appendingPathComponent(primaryImageName)
        do {
            if fm.fileExists(atPath: finalImgPath) {
                _ = try fm.replaceItemAt(
                    URL(fileURLWithPath: finalImgPath),
                    withItemAt: URL(fileURLWithPath: pulledFilePath)
                )
            } else {
                try fm.moveItem(atPath: pulledFilePath, toPath: finalImgPath)
            }
            let markerPath = (destDir as NSString).appendingPathComponent(".titleid")
            try (canonicalTID + "\n").write(toFile: markerPath, atomically: true, encoding: .utf8)
            if let expected = expectedIdentity?.trimmingCharacters(in: .whitespacesAndNewlines),
               expected.hasPrefix("DMROMFSID1 ") {
                try? (expected + "\n").write(toFile: finalImgPath + ".id", atomically: true, encoding: .utf8)
            }
            committed = true
            return .success(finalImgPath)
        } catch {
            return .failure(.transferFailed(error.localizedDescription))
        }
    }

    private static func selectRemoteImageName(from listing: [String: Int64], folderHint: String) -> String? {
        var topLevel: [String] = []
        for rawKey in listing.keys {
            var cleaned = rawKey
            while cleaned.hasPrefix("./") {
                cleaned = String(cleaned.dropFirst(2))
            }
            while cleaned.hasPrefix("/") {
                cleaned = String(cleaned.dropFirst())
            }
            guard !cleaned.isEmpty,
                  !cleaned.hasPrefix("."),
                  !cleaned.contains("/"),
                  !cleaned.contains("\\") else {
                continue
            }
            let lower = cleaned.lowercased()
            guard (lower as NSString).pathExtension == "img",
                  !lower.contains(".nxpart") else {
                continue
            }
            if !topLevel.contains(cleaned) {
                topLevel.append(cleaned)
            }
        }
        guard !topLevel.isEmpty else { return nil }
        let sorted = topLevel.sorted()
        if let primary = RomFSArchive.primaryImageName(inFiles: sorted, folderName: folderHint) {
            return primary
        }
        if let primary = RomFSArchive.primaryImageName(inFiles: sorted, folderName: nil) {
            return primary
        }
        return sorted.first
    }

    private static func locatePulledFile(tempDest: String, remoteImg: String, fm: FileManager) -> String? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: tempDest, isDirectory: &isDir) else {
            return nil
        }
        if !isDir.boolValue {
            return tempDest
        }
        let exactNested = (tempDest as NSString).appendingPathComponent(remoteImg)
        var nestedDir: ObjCBool = false
        if fm.fileExists(atPath: exactNested, isDirectory: &nestedDir), !nestedDir.boolValue {
            return exactNested
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: tempDest) else {
            return nil
        }
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            guard (entry as NSString).pathExtension.lowercased() == "img" else { continue }
            let candidate = (tempDest as NSString).appendingPathComponent(entry)
            var subDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &subDir), !subDir.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func cleanErrorLine(_ output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last(where: { $0.lowercased().contains("error") }) ?? lines.last ?? "devicectl copy failed"
    }
}
