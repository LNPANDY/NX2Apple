import Foundation
import NXCore

package enum BuildCompletionStatus: Equatable { case mac, installed, exported, needsData }

extension BuildStore {
    /// A recorded result, never an inference from an artifact alone or from translated status text.
    package var completionStatus: BuildCompletionStatus? {
        guard !running, !stoppedByPlayer, failure == nil else { return nil }
        if !done, let completedOperation, completedOperation != .sendingGameData { return nil }
        if completedOperation == .installing, done, !installedOn.isEmpty {
            return installedDataComplete == false && !archivePath.isEmpty ? .needsData : .installed
        }
        if !exportedIPAPath.isEmpty, done || send != .idle { return .exported }
        if !installedOn.isEmpty {
            if installedDataComplete == false, !archivePath.isEmpty { return .needsData }
            if done || installedDataComplete == true { return .installed }
        }
        if done, runningTarget == BuildTarget.mac, !macAppPath.isEmpty { return .mac }
        return nil
    }
    package var completedFramework: Bool { !exportedIPAPath.isEmpty && URL(fileURLWithPath: exportedIPAPath).pathExtension.lowercased() == "framework" }
    package var completedOneGameIPA: Bool { !oneGameIPAPath.isEmpty && oneGameIPAPath == exportedIPAPath }
}
