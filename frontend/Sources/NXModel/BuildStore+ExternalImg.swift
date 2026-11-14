import Foundation
import NXCore

extension BuildStore {
    /// Updates the embedded `DMMSLTR1` iOS shader trailer directly inside an external RomFS `.img` without copying it locally.
    @discardableResult
    package nonisolated static func updateExternalImageTrailerInPlace(
        imgPath: String,
        workDir: String,
        tid: String,
        repoPath: String,
        pythonPath: String,
        runner: ProcessRunner,
        fm: FileManager = .default,
        onNote: (String) -> Void = { _ in }
    ) -> Bool {
        let trimmed = imgPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: trimmed, isDirectory: &isDir), !isDir.boolValue else {
            onNote("External image not found at \(trimmed)")
            return false
        }
        guard fm.isWritableFile(atPath: trimmed) else {
            onNote("External image is read-only, skipping in-place trailer update: \(trimmed)")
            return false
        }

        switch Self.injectIOSShaderTrailerIfNeeded(
            targetImg: trimmed,
            workDir: workDir,
            tid: tid,
            isIOSBuild: true,
            repoPath: repoPath,
            pythonPath: pythonPath,
            runner: runner,
            fm: fm
        ) {
        case .success(let logLine):
            if let logLine, !logLine.isEmpty {
                onNote(logLine)
            }
            return true
        case .failure(let err):
            if !err.message.isEmpty {
                onNote("⚠ " + err.message)
            } else {
                onNote("⚠ Failed to update shader trailer on external image (exit \(err.status))")
            }
            return false
        }
    }
}
