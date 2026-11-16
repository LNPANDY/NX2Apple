import Foundation

package enum S2ArmBuilder {
    package static var featureEnabled = ProcessInfo.processInfo.environment["NX2APPLE_MULTI_UPSTREAM"] != "0"

    package struct ResultSummary: Equatable, Sendable {
        package let ok: Bool
        package let ipaPath: String?
        package let packPath: String?
        package let macRootPath: String?
        package let message: String?

        package init(
            ok: Bool,
            ipaPath: String? = nil,
            packPath: String? = nil,
            macRootPath: String? = nil,
            message: String? = nil
        ) {
            self.ok = ok
            self.ipaPath = ipaPath
            self.packPath = packPath
            self.macRootPath = macRootPath
            self.message = message
        }
    }

    package static let macOneClickScript = "pack/oneclick/oneclick.sh"

    package static func scriptPath(in tree: String) -> String {
        let prefix = tree.hasSuffix("/") ? tree : tree + "/"
        return prefix + macOneClickScript
    }

    package static func isUsableTree(_ directory: String, fileManager fm: FileManager = .default) -> Bool {
        EngineUpstream.isTree(directory, kind: .s2arm, fileManager: fm) && fm.fileExists(atPath: scriptPath(in: directory))
    }

    package static func arguments(
        tree: String,
        sourceInput: String,
        keysPath: String,
        isUnencryptedInput: Bool,
        workDir: String,
        isMacTarget: Bool,
        titleID: String?,
        deviceUDID: String?,
        eventsFile: String
    ) -> [String] {
        var args = [scriptPath(in: tree), sourceInput]
        if !isUnencryptedInput && !keysPath.isEmpty {
            args += ["--keys", keysPath]
        }
        args += ["--out", workDir, "--target", isMacTarget ? "mac" : "ios"]
        if let titleID {
            let tid = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !tid.isEmpty {
                args += ["--title-id", tid]
            }
        }
        if !isMacTarget, let deviceUDID {
            let dev = deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !dev.isEmpty {
                args += ["--device", dev]
            }
        }
        if !eventsFile.isEmpty {
            args += ["--events", eventsFile]
        }
        return args
    }

    package static func environment(pythonPath: String, keysPath: String, isUnencryptedInput: Bool) -> [String: String] {
        var env: [String: String] = [
            "S2A_PYTHON": pythonPath,
            "PYTHONUNBUFFERED": "1"
        ]
        if !isUnencryptedInput && !keysPath.isEmpty {
            env["S2A_KEYS"] = keysPath
        }
        return env
    }

    package static func parseEvents(_ text: String) -> ResultSummary? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let data = String(line).data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (dict["ev"] as? String) == "result" else {
                continue
            }
            let ok = (dict["ok"] as? Bool) ?? false
            let ipaPath = (dict["ipa"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let packPath = (dict["pack"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let macRootPath = (dict["root"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let message = (dict["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ResultSummary(
                ok: ok,
                ipaPath: ipaPath,
                packPath: packPath,
                macRootPath: macRootPath,
                message: message
            )
        }
        return nil
    }

    package static func lastError(in log: String, eventsText: String? = nil) -> String? {
        if let eventsText, let summary = parseEvents(eventsText), !summary.ok, let msg = summary.message, !msg.isEmpty {
            return msg
        }
        let lines = log.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.contains("🔴") || trimmed.contains("【红】") || trimmed.hasPrefix("ERROR:") {
                return trimmed
            }
        }
        return BuildProgress.lastMeaningfulLine(log)
    }
}
