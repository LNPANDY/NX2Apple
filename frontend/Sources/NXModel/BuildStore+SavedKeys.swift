import Foundation
import NXCore

// The prod.keys chosen once (LNPANDY/NX2Apple#996): Settings, "Keys", keeps one file for every game. A build whose keys row is empty,
// or names a file that is gone, takes it. A game folder (a Switch 2 game) needs no keys and never takes them. The keys are saved only
// when the player chooses a file (here, on the keys row, by dropping the file itself, in the guided setup), never from a folder scan.

extension BuildStore {
    /// The keys row's own file, empty when the row is.
    package var keysRowPath: String { slot("keys").paths.first ?? "" }

    /// The keys row has no usable file and the saved keys stand in for it. Never for a game folder.
    package var keysFromSettings: Bool {
        gameFolder == nil && !FileManager.default.fileExists(atPath: keysRowPath) && savedKeysExist
    }

    /// The saved keys are chosen and still there.
    package var savedKeysExist: Bool { !savedKeys.isEmpty && FileManager.default.fileExists(atPath: savedKeys) }

    /// The keys the build passes with -k: the row's file, else the saved keys, else what the row names (empty or gone, which the
    /// build then reports). A game folder's are its row's, which is empty: it needs none.
    package var keysPath: String { keysFromSettings ? savedKeys : keysRowPath }

    /// A keys file the build can read: the row's or the saved one.
    package var keysReady: Bool { FileManager.default.fileExists(atPath: keysPath) }

    /// Keeps `path` as the keys of every game (an explicit choice of the player).
    package func saveKeys(_ path: String) {
        guard !path.isEmpty else { return }
        savedKeys = path
    }

    /// Settings, Remove (and Skip in the guided setup): no keys are saved any more. The rows keep the files they name.
    package func forgetSavedKeys() { savedKeys = "" }

    /// Settings, Choose: the open panel for one keys file, which is saved.
    package func chooseSavedKeys() {
        let picked = choosePaths(FilePick(allowsMultiple: false, fileTypes: GameInputs.allowedFileTypes(for: .keys)))
        guard let path = picked.first else { return }
        saveKeys(path)
    }
}
