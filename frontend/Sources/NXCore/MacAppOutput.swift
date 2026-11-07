import Foundation

/// A first build learns the name and title ID from the app the packer actually produced. Rebuilds go straight to the
/// game's existing bundle so the packer can reuse it, or replace it safely on APFS and other volumes.
package struct MacAppOutput {
    package let builderURL: URL
    private let directory: URL
    private let rebuilding: Bool

    package init(workDir: URL, key: String, titleID: String?, preferred: String) {
        directory = workDir.deletingLastPathComponent()
        let prior = Self.existing(in: directory, titleID: titleID, preferred: preferred)
        rebuilding = prior != nil
        builderURL = prior ?? workDir.appendingPathComponent(key + ".app")
    }

    /// Only the chosen output folder counts. Never hand the packer a symlink to an app on another drive or in another library.
    package static func existing(in directory: URL, titleID: String?, preferred: String = "") -> URL? {
        guard let titleID else { return nil }
        func matches(_ url: URL) -> Bool {
            url.pathExtension.lowercased() == "app" &&
                (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false &&
                (try? MacGameBundle.read(url))?.titleID == titleID
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
            let prior = rebuilding ? packed : Self.existing(in: directory, titleID: info.titleID)
            if let prior, !rebuilding {
                // A package without an ID in its filename can only identify an earlier app now.
                _ = try fm.replaceItemAt(prior, withItemAt: packed, options: .usingNewMetadataOnly)
                movePackingKey(from: packed, to: prior)
                packed = prior
            }
            let result: URL
            if let prior, prior.deletingPathExtension().lastPathComponent.uppercased() != info.titleID {
                result = prior  // keep the user's chosen filename
            } else {
                result = try place(packed, title: Self.filename(info.displayName, fallback: info.titleID), titleID: info.titleID)
            }
            // Saves and logs follow this output folder when the library moves.
            try? Data().write(to: directory.appendingPathComponent(".nx2apple-library"))
            return result
        } catch {
            guard fm.fileExists(atPath: packed.path) else { throw FinishError.missingApp }
            throw FinishError.retainedApp(packed, error)
        }
    }

    private func place(_ source: URL, title: String, titleID: String) throws -> URL {
        for name in [title, title + " [" + titleID + "]", titleID] {
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
        let target = directory.appendingPathComponent(titleID + "-" + UUID().uuidString + ".app")
        try FileManager.default.moveItem(at: source, to: target)
        movePackingKey(from: source, to: target)
        return target
    }

    private static func filename(_ title: String?, fallback: String) -> String {
        let separators = CharacterSet(charactersIn: " .-")
        let cleaned = (title ?? "").replacingOccurrences(of: #"[\s\p{Cc}]*[:/]+[\s\p{Cc}]*"#, with: " - ", options: .regularExpression)
            .replacingOccurrences(of: #"[\s\p{Cc}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: separators)
        // Leave room for the title ID on a collision and for the engine's .app.key.partial and .app.partial siblings.
        var stem = ""
        for character in cleaned {
            guard stem.utf8.count + String(character).utf8.count <= 215 else { break }
            stem.append(character)
        }
        return stem.isEmpty ? fallback : stem
    }

    private func movePackingKey(from: URL, to: URL) {
        // The next build can regenerate this fingerprint. Never overwrite an unrelated file with it.
        try? FileManager.default.moveItem(at: from.appendingPathExtension("key"), to: to.appendingPathExtension("key"))
    }
}
