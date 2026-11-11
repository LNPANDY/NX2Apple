import Foundation

/// The early stops of the NSP script that the launcher can turn into a next step. The script prints a
/// `[RED]` line and exits 1 for each (a `BuildError`), and the launcher used to show only the last line of
/// the log, cut to 200 characters. The classifier reads the whole log tail, because for a damaged NSP the
/// last line is only "nx_extract exit code 3" and the message is a few lines above it.
package enum BuildFailureKind: String, CaseIterable {
    case rosetta, translator, zbic, iosSDK, cltSelected, metalToolchain, otherMetal, shaderRegression, damagedNSP, a32Program
    /// The inputs: the keys file, the game folder, a drive that is gone.
    case keys, severalGames, noTitleID, driveMissing
    /// prod.keys lacks the master key the game needs: the keys are older than the game (nx_extract's exit code 6, seedds/nxnative 3104c0a).
    case keysOld
    /// A provisional profile kept from an earlier build registers other versions than the selected update (scripts/build_ipa_from_nsp.py provisional_version): the script stops
    /// rather than pack an older version, and keeps the profile. `detail` is the folder it names.
    case staleProfile
    /// The selected update or game build does not match the versions registered by the game profile.
    case updateMismatch
    /// The build's and the install's own steps.
    /// The offline Metal archive ran out of space or stopped at its own space estimate.
    case psoDiskFull
    case diskFull, teamTaken, noSigningAccount, freeAccountLimit, appIDLimit, deviceTransfer
    /// The build folder is in iCloud Drive or another cloud folder (CloudFolder.swift): the launcher stops before the build, and the
    /// codesign line of xcodebuild is the same stop for a build that got past that check.
    case cloudFolder
    /// The output folder is on a disk that cannot replace the old Mac app (anything but APFS, OutputVolume.swift): the launcher stops before the
    /// build when the app is there already, and the engine's `[Errno 45] Operation not supported` is the same stop for a build that got past that check.
    case volumeFormat
    /// The shared app's install: a device this Mac never paired, and game data that went over only in part.
    case devicePairing, shellDataIncomplete
    /// The engine's online sync (tools/engine.py sync, EngineLayout.swift): no network or GitHub unreachable, or any other stop of it.
    case engineOffline, engineSync
    case unknown

    /// The script's override for this stop, offered as "Build anyway". Only these three have one that the launcher
    /// may offer: the others cannot be built around (a 32-bit program, a missing SDK).
    package var overrideFlag: String? {
        switch self {
        case .otherMetal: return "--allow-other-metal"
        case .shaderRegression: return "--allow-shader-regressions"
        case .damagedNSP: return "--allow-damaged"
        default: return nil
        }
    }

    /// L10n keys: what happened, and the next step.
    package var whatKey: String {
        switch self {
        case .metalToolchain: return "macFail.metalToolchain.what"
        case .updateMismatch: return "macFail.updateMismatch.what"
        case .freeAccountLimit: return "macFail.freeAccountLimit.what"
        default: return "fail.\(rawValue).what"
        }
    }

    package var nextKey: String {
        switch self {
        case .metalToolchain: return "macFail.metalToolchain.next"
        case .updateMismatch: return "macFail.updateMismatch.next"
        case .freeAccountLimit: return "macFail.freeAccountLimit.next"
        default: return "fail.\(rawValue).next"
        }
    }
}

package struct BuildFailure: Equatable {
    package var kind: BuildFailureKind
    package var gameName: String?   // a32Program: the game, when the message names it
    /// What the message adds to its row: the GB a full disk needs (diskFull, psoDiskFull), the drive's name (driveMissing), the folder
    /// of "no NSP with a readable title ID" (noTitleID).
    package var detail: String? = nil

    package var titleIDs: [String] = []  // severalGames: choices the engine offers with --title-id

    package init(kind: BuildFailureKind, gameName: String?, detail: String? = nil) {
        self.kind = kind
        self.gameName = gameName
        self.detail = detail
    }
}
