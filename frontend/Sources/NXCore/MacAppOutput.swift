import Foundation

/// A first build learns the name and title ID from the app the packer actually produced. Rebuilds go straight to the
/// game's existing bundle of the same `(titleID, upstream)` so the packer can reuse it, or replace it safely without
/// overwriting other engines' builds of the same game.
package struct MacAppOutput {
    package let builderURL: URL
    package let workDirectoryURL: URL
    package let stagingDirectoryURL: URL?
    package let upstream: EngineUpstreamKind
    private let directory: URL
    private let rebuilding: Bool

    package init(workDir: URL, key: String, titleID: String?, upstream: EngineUpstreamKind = .nxnative, preferred: String, stagingDirectory: URL? = nil) {
        workDirectoryURL = workDir
        self.upstream = upstream
        directory = workDir.deletingLastPathComponent()
        let prior = Self.existing(in: directory, titleID: titleID, upstream: upstream, preferred: preferred)
        rebuilding = prior != nil
        if let prior {
            stagingDirectoryURL = nil
            builderURL = prior
        } else if let stagingDirectory {
            stagingDirectoryURL = stagingDirectory
            builderURL = stagingDirectory.appendingPathComponent(key + ".app")
        } else {
            stagingDirectoryURL = nil
            builderURL = workDir.appendingPathComponent(key + ".app")
        }
    }

    /// Removes `stagingDirectoryURL` when it was created for a separate first-build output and is now empty.
    package func cleanupEmptyStagingDirectory(fileManager fm: FileManager = .default) {
        guard let stagingDirectoryURL else { return }
        if ((try? fm.contentsOfDirectory(atPath: stagingDirectoryURL.path)) ?? ["-"]).isEmpty {
            try? fm.removeItem(at: stagingDirectoryURL)
        }
    }

    /// Only the chosen output folder counts, matching `(titleID, upstream)` so different engines never overwrite each other.
    package static func existing(in directory: URL, titleID: String?, upstream: EngineUpstreamKind = .nxnative, preferred: String = "") -> URL? {
        guard let titleID else { return nil }
        func matches(_ url: URL) -> Bool {
            url.pathExtension.lowercased() == "app" &&
                (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false &&
                (try? MacGameBundle.read(url))?.titleID == titleID &&
                (try? MacGameBundle.read(url))?.upstream == upstream
        }
        if !preferred.isEmpty {
            let app = URL(fileURLWithPath: preferred)
            if app.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path,
               matches(app) { return app }
        }
        let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        return children?.sorted { $0.lastPathComponent < $1.lastPathComponent }.first(where: matches)
    }

    package enum FinishError: Error {
        case missingApp
        case retainedApp(URL, Error)
    }

    package func finish() throws -> URL {
        let fm = FileManager.default
        var packed = builderURL
        do {
            let info = try MacGameBundle.read(packed)
            let resolvedUpstream = info.upstream == .nxnative && upstream != .nxnative ? upstream : info.upstream
            let prior = rebuilding ? packed : Self.existing(in: directory, titleID: info.titleID, upstream: resolvedUpstream)
            if let prior, !rebuilding {
                // A package without an ID in its filename can only identify an earlier app of the same engine now.
                _ = try fm.replaceItemAt(prior, withItemAt: packed, options: .usingNewMetadataOnly)
                movePackingKey(from: packed, to: prior)
                packed = prior
            }
            let suffix = resolvedUpstream.appFilenameSuffix
            let rawTidStem = suffix.isEmpty ? info.titleID : "\(info.titleID) [\(suffix)]"
            let result: URL
            if let prior, prior.deletingPathExtension().lastPathComponent.uppercased() != rawTidStem.uppercased() {
                result = prior  // keep the user's chosen filename
            } else {
                result = try place(packed, title: Self.filename(info.displayName, fallback: info.titleID, suffix: suffix), titleID: info.titleID, suffix: suffix)
            }
            // Saves and logs follow this output folder when the library moves.
            try? Data().write(to: directory.appendingPathComponent(".nx2apple-library"))
            cleanupEmptyStagingDirectory(fileManager: fm)
            return result
        } catch {
            guard fm.fileExists(atPath: packed.path) else { throw FinishError.missingApp }
            throw FinishError.retainedApp(packed, error)
        }
    }

    private func place(_ source: URL, title: String, titleID: String, suffix: String) throws -> URL {
        let candidates: [String]
        if suffix.isEmpty {
            candidates = [title, title + " [" + titleID + "]", titleID]
        } else {
            candidates = [
                "\(title) [\(suffix)]",
                "\(title) [\(suffix)] [\(titleID)]",
                "\(titleID) [\(suffix)]",
            ]
        }
        for name in candidates {
            let target = directory.appendingPathComponent(name + ".app")
            if source.standardizedFileURL.path == target.standardizedFileURL.path { return source }
            do {
                // moveItem refuses an occupied destination, including another game that finished in the meantime.
                try FileManager.default.moveItem(at: source, to: target)
                movePackingKey(from: source, to: target)
                return target
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        let fallbackStem = suffix.isEmpty ? titleID : "\(titleID) [\(suffix)]"
        let target = directory.appendingPathComponent(fallbackStem + "-" + UUID().uuidString + ".app")
        try FileManager.default.moveItem(at: source, to: target)
        movePackingKey(from: source, to: target)
        return target
    }

    private static func filename(_ title: String?, fallback: String, suffix: String = "") -> String {
        let separators = CharacterSet(charactersIn: " .-")
        let cleaned = (title ?? "").replacingOccurrences(of: #"[\s\p{Cc}]*[:/]+[\s\p{Cc}]*"#, with: " - ", options: .regularExpression)
            .replacingOccurrences(of: #"[\s\p{Cc}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: separators)
        // Leave room for the engine suffix, the title ID on a collision, and .app.key.partial siblings.
        let suffixReserve = suffix.isEmpty ? 0 : suffix.utf8.count + 3
        let maxBytes = max(40, 215 - suffixReserve)
        var stem = ""
        for character in cleaned {
            guard stem.utf8.count + String(character).utf8.count <= maxBytes else { break }
            stem.append(character)
        }
        return stem.isEmpty ? fallback : stem
    }

    private func movePackingKey(from: URL, to: URL) {
        // The next build can regenerate this fingerprint. Never overwrite an unrelated file with it.
        try? FileManager.default.moveItem(at: from.appendingPathExtension("key"), to: to.appendingPathExtension("key"))
    }
}
