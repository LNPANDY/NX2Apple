import Foundation

/// Adds optional user data before the caller signs a newly built Mac app.
/// Does not import into live saves or modify the input folders.
package enum OfflineAppSeed {
    /// Work on a sibling copy so even a signer that partially mutates Mach-O files
    /// cannot damage the original build. Publish only after strict verification.
    package static func prepareCopy(app: URL, save: URL?, caches: URL?, cancelled: () -> Bool = { false }, copyApp: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }, finalize: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let candidate = app.deletingLastPathComponent().appendingPathComponent(".offline-candidate-" + UUID().uuidString + ".app")
        do {
            if cancelled() { throw CancellationError() }
            try copyApp(app, candidate)
            try install(app: candidate, save: save, caches: caches, cancelled: cancelled, finalize: { try finalize(candidate) })
            if cancelled() { throw CancellationError() }
            return candidate
        } catch {
            try? fm.removeItem(at: candidate)
            throw error
        }
    }

    package static func install(app: URL, save: URL?, caches: URL?, cancelled: () -> Bool = { false }, finalize: () throws -> Void = {}) throws {
        guard save != nil || caches != nil else { return }
        if cancelled() { throw CancellationError() }
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        let plist = contents.appendingPathComponent("Info.plist")
        let originalPlist = try Data(contentsOf: plist)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: &format) as? [String: Any],
              let original = info["CFBundleExecutable"] as? String,
              original == "nxnative",
              let identifier = info["CFBundleIdentifier"] as? String,
              !identifier.isEmpty, identifier.count <= 200,
              identifier.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil,
              !identifier.contains("..") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let seed = contents.appendingPathComponent("Resources/offline-seed")
        let wrapper = contents.appendingPathComponent("MacOS/offline-launch")
        guard !fm.fileExists(atPath: seed.path), !fm.fileExists(atPath: wrapper.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try OfflineDataInventory.stage(save: save, caches: caches, destination: seed, cancelled: cancelled)
        do {
            try launcher(identifier: identifier).write(to: wrapper, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            info["CFBundleExecutable"] = "offline-launch"
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
            try data.write(to: plist, options: .atomic)
            if cancelled() { throw CancellationError() }
            try finalize()
        } catch {
            // Restore the entry point before removing the files it referenced.
            try originalPlist.write(to: plist, options: .atomic)
            try? fm.removeItem(at: wrapper)
            try? fm.removeItem(at: seed)
            throw error
        }
    }

    /// Restore a displaced original only if its path is absent. Keep recovery
    /// artifacts on error rather than overwrite a concurrently published app.
    package static func publish(candidate: URL, over app: URL, replace: (URL, URL, String) throws -> Void = { app, candidate, backup in
        _ = try FileManager.default.replaceItemAt(app, withItemAt: candidate, backupItemName: backup, options: .withoutDeletingBackupItem)
    }) throws {
        let backupName = app.lastPathComponent + ".before-offline-" + UUID().uuidString
        let backup = app.deletingLastPathComponent().appendingPathComponent(backupName)
        do {
            try replace(app, candidate, backupName)
        } catch {
            let fm = FileManager.default
            if !fm.fileExists(atPath: app.path), fm.fileExists(atPath: backup.path) {
                try fm.moveItem(at: backup, to: app)
            }
            throw error
        }
    }

    package static func launcher(identifier: String) -> String {
        """
        #!/bin/sh
        set -eu
        HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        SEED="$HERE/../Resources/offline-seed"
        ROOT="$HOME/Library/Application Support/nxnative/offline/\(identifier)"
        if [ ! -f "$ROOT/.seed-ready" ]; then
          if [ -e "$ROOT" ]; then
            echo "Refusing to replace existing offline data: $ROOT" >&2
            exit 1
          fi
          mkdir -p "$(dirname -- "$ROOT")"
          STAGE=$(mktemp -d "${ROOT}.stage.XXXXXX")
          /usr/bin/ditto "$SEED" "$STAGE"
          touch "$STAGE/.seed-ready"
          if [ -e "$ROOT" ]; then
            echo "Preserved staged offline data: $STAGE" >&2
            exit 1
          fi
          mv -n "$STAGE" "$ROOT"
          test ! -e "$STAGE" || exit 1
        fi
        mkdir -p "$ROOT/save" "$ROOT/temp"
        export DM_SAVE="$ROOT/save"
        export DM_TEMP="$ROOT/temp"
        # Imported data stays local until the user explicitly configures synchronization.
        export DM_SAVE_SYNC=0
        exec "$HERE/nxnative" "$@"

        """
    }
}
