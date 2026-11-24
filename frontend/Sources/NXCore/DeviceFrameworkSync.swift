import Foundation

/// A hot-loaded `DmGame<TID>.framework` directory discovered in `Documents/Frameworks/` on a paired iOS device.
package struct DeviceFrameworkEntry: Equatable, Codable, Sendable {
    package var titleID: String
    package var frameworkName: String
    package var bundleID: String
    package var deviceUDID: String
    package var deviceName: String

    package init(
        titleID: String,
        frameworkName: String,
        bundleID: String,
        deviceUDID: String,
        deviceName: String
    ) {
        self.titleID = titleID
        self.frameworkName = frameworkName
        self.bundleID = bundleID
        self.deviceUDID = deviceUDID
        self.deviceName = deviceName
    }
}

/// Status of probing `Documents/Frameworks` on a paired iOS device.
package enum DeviceFrameworkProbeState: Equatable, Sendable {
    case idle
    case probing
    case ready
    case noShellApp
    case restricted(String)
    case failed(String)
}

/// Aggregate result of probing a paired iOS device for installed `DmGame<TID>.framework` directories.
package struct DeviceFrameworkDiscoveryResult: Equatable, Sendable {
    package var deviceUDID: String
    package var deviceName: String
    package var bundleID: String
    package var state: DeviceFrameworkProbeState
    package var entries: [DeviceFrameworkEntry]

    package init(
        deviceUDID: String,
        deviceName: String,
        bundleID: String = "",
        state: DeviceFrameworkProbeState,
        entries: [DeviceFrameworkEntry] = []
    ) {
        self.deviceUDID = deviceUDID
        self.deviceName = deviceName
        self.bundleID = bundleID
        self.state = state
        self.entries = entries
    }
}

/// Pure parsing, validation, and `devicectl` listing helpers for device-resident `DmGame<TID>.framework` directories.
package enum DeviceFrameworkSync {
    package static let frameworksSubdirectory = "Documents/Frameworks"
    package static let remoteStagingPrefix = ".staging-"

    private static let titleIDRegex = try! NSRegularExpression(pattern: #"^[0-9A-F]{16}$"#)

    /// Validates a 16-character uppercase hex Nintendo Switch Title ID.
    package static func isValidTitleID(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        return titleIDRegex.firstMatch(in: trimmed, range: range) != nil
    }

    /// Rejects absolute paths, Windows/backslash paths, colon segments, NUL bytes, `.`, and `..` traversal.
    package static func isSafeRelativePath(_ relPath: String) -> Bool {
        guard !relPath.isEmpty,
              !relPath.hasPrefix("/"),
              !relPath.hasPrefix("\\"),
              !relPath.contains("\\"),
              !relPath.contains(":"),
              !relPath.contains("\0") else {
            return false
        }
        let segments = relPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return false }
        return !segments.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// `devicectl` arguments for listing `Documents/Frameworks` on a paired device.
    package static func listFrameworksArguments(device: String, bundleID: String, jsonPath: String) -> [String] {
        [
            "device", "info", "files",
            "--device", device,
            "--domain-type", "appDataContainer",
            "--domain-identifier", bundleID,
            "--subdirectory", frameworksSubdirectory,
            "--json-output", jsonPath,
        ]
    }

    /// Classifies `devicectl` error output when accessing an app container fails due to release signing / missing `get-task-allow`.
    package static func isPermissionRefusal(_ output: String) -> Bool {
        let lower = output.lowercased()
        let signals = [
            "get-task-allow",
            "not entitled",
            "entitlement",
            "permission denied",
            "operation not permitted",
            "does not allow",
            "access denied",
            "sandbox",
            "com.apple.security.get-task-allow",
            "not debuggable",
            "application is not debuggable",
        ]
        return signals.contains { lower.contains($0) }
    }

    /// Parses `xcrun devicectl device info files --subdirectory Documents/Frameworks --json-output` into validated entries.
    /// Returns `nil` when JSON cannot be decoded. Identifies `DmGame<TID>.framework` directories (plus `.ready`-verified staging folders)
    /// while rejecting symlinks, unsafe paths, and invalid Title IDs.
    package static func parseFrameworksListing(
        _ data: Data,
        deviceUDID: String,
        deviceName: String,
        bundleID: String
    ) -> [DeviceFrameworkEntry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let files = result["files"] as? [[String: Any]] else {
            return nil
        }

        var readyStagingRoots = Set<String>()
        for item in files {
            guard let rel = item["relativePath"] as? String, isSafeRelativePath(rel) else { continue }
            let parts = rel.split(separator: "/").map(String.init)
            if parts.count == 2,
               parts[0].hasPrefix(remoteStagingPrefix),
               parts[1] == ".ready" {
                readyStagingRoots.insert(parts[0])
            }
        }

        func parseFrameworkTitleID(_ folderName: String) -> String? {
            guard folderName.hasPrefix("DmGame"), folderName.hasSuffix(".framework") else { return nil }
            let raw = String(folderName.dropFirst("DmGame".count).dropLast(".framework".count)).uppercased()
            return isValidTitleID(raw) ? raw : nil
        }

        var candidateNames: [String: String] = [:]
        var taintedTitleIDs = Set<String>()

        for item in files {
            guard let rel = item["relativePath"] as? String else { continue }
            let resources = item["resources"] as? [String: Any] ?? [:]
            let isDir = resources["isDirectory"] as? Bool ?? false
            let isSymlink = resources["isSymbolicLink"] as? Bool ?? false

            guard isSafeRelativePath(rel) else {
                let parts = rel.split(separator: "/").map(String.init)
                if let first = parts.first, let tid = parseFrameworkTitleID(first) {
                    taintedTitleIDs.insert(tid)
                } else if parts.count >= 2,
                          parts[0].hasPrefix(remoteStagingPrefix),
                          let tid = parseFrameworkTitleID(parts[1]) {
                    taintedTitleIDs.insert(tid)
                }
                continue
            }

            let parts = rel.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }

            let tid: String
            let fwName: String
            let isFrameworkDirEntry: Bool

            if let parsedTID = parseFrameworkTitleID(parts[0]) {
                tid = parsedTID
                fwName = "DmGame\(tid).framework"
                isFrameworkDirEntry = parts.count == 1 && isDir
            } else if parts.count >= 2,
                      readyStagingRoots.contains(parts[0]),
                      let parsedTID = parseFrameworkTitleID(parts[1]),
                      parts[0].uppercased().hasPrefix(remoteStagingPrefix.uppercased() + parsedTID) {
                tid = parsedTID
                fwName = "DmGame\(tid).framework"
                isFrameworkDirEntry = parts.count == 2 && isDir
            } else {
                continue
            }

            if isSymlink {
                taintedTitleIDs.insert(tid)
                continue
            }
            if isFrameworkDirEntry {
                candidateNames[tid] = fwName
            }
        }

        return candidateNames
            .filter { !taintedTitleIDs.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { tid, fwName in
                DeviceFrameworkEntry(
                    titleID: tid,
                    frameworkName: fwName,
                    bundleID: bundleID,
                    deviceUDID: deviceUDID,
                    deviceName: deviceName
                )
            }
    }

    /// Discovers `DmGame<TID>.framework` directories in `Documents/Frameworks/` on a paired iOS device via `DeviceControl`.
    package static func discoverFrameworks(
        deviceUDID: String,
        deviceName: String,
        preferredBundleID: String = "",
        control: DeviceControl,
        fm: FileManager = .default
    ) -> DeviceFrameworkDiscoveryResult {
        let trimmedUDID = deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUDID.isEmpty else {
            return DeviceFrameworkDiscoveryResult(deviceUDID: "", deviceName: deviceName, state: .failed("empty device"))
        }

        let tmpDir = NSTemporaryDirectory() + "nspb-dfw-probe-\(UUID().uuidString.prefix(8))"
        defer { try? fm.removeItem(atPath: tmpDir) }
        do {
            try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        } catch {
            return DeviceFrameworkDiscoveryResult(
                deviceUDID: trimmedUDID,
                deviceName: deviceName,
                state: .failed(error.localizedDescription)
            )
        }

        let appsJSON = tmpDir + "/apps.json"
        let appsResult = control.run(InstalledApps.listArguments(device: trimmedUDID, json: appsJSON))
        guard appsResult.ok,
              let appsData = fm.contents(atPath: appsJSON),
              let apps = InstalledApps.parse(appsData) else {
            if isPermissionRefusal(appsResult.output) {
                return DeviceFrameworkDiscoveryResult(
                    deviceUDID: trimmedUDID,
                    deviceName: deviceName,
                    state: .restricted(appsResult.output)
                )
            }
            return DeviceFrameworkDiscoveryResult(
                deviceUDID: trimmedUDID,
                deviceName: deviceName,
                state: .failed(appsResult.output.isEmpty ? "failed to list installed apps" : appsResult.output)
            )
        }

        var shellCandidates = ShellInstall.shellApps(in: apps).map(\.bundle)
        if shellCandidates.isEmpty {
            return DeviceFrameworkDiscoveryResult(deviceUDID: trimmedUDID, deviceName: deviceName, state: .noShellApp)
        }
        let pref = preferredBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pref.isEmpty, let idx = shellCandidates.firstIndex(of: pref) {
            let chosen = shellCandidates.remove(at: idx)
            shellCandidates.insert(chosen, at: 0)
        }

        var lastRefusal: String?
        var lastError: String?

        for (candidateIndex, bundleID) in shellCandidates.enumerated() {
            let fwJSON = tmpDir + "/frameworks-\(candidateIndex).json"
            let fwResult = control.run(listFrameworksArguments(device: trimmedUDID, bundleID: bundleID, jsonPath: fwJSON))
            if !fwResult.ok {
                if isPermissionRefusal(fwResult.output) {
                    lastRefusal = fwResult.output
                } else {
                    lastError = fwResult.output
                }
                continue
            }
            guard let fwData = fm.contents(atPath: fwJSON),
                  let entries = parseFrameworksListing(
                      fwData,
                      deviceUDID: trimmedUDID,
                      deviceName: deviceName,
                      bundleID: bundleID
                  ) else {
                lastError = "unreadable framework listing"
                continue
            }

            return DeviceFrameworkDiscoveryResult(
                deviceUDID: trimmedUDID,
                deviceName: deviceName,
                bundleID: bundleID,
                state: .ready,
                entries: entries
            )
        }

        if let refusal = lastRefusal {
            return DeviceFrameworkDiscoveryResult(deviceUDID: trimmedUDID, deviceName: deviceName, state: .restricted(refusal))
        }
        return DeviceFrameworkDiscoveryResult(
            deviceUDID: trimmedUDID,
            deviceName: deviceName,
            state: .failed(lastError ?? "failed to inspect Documents/Frameworks")
        )
    }
}
