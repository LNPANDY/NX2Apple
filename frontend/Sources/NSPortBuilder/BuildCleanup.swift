import Foundation

/// What happens to a game's build folder (<output folder>/<title ID>_build) after a build succeeded.
///
/// A player builds a game once and plays it: the app (or the IPA and the game data archive) holds everything the game needs,
/// and the build folder only serves the next build (Breath of the Wild: a 17 GB app, a 31 GB build folder). So the default
/// removes it, with the same parts the Free space sheet offers (`BuildFolder.remove`), and "Keep build files" in Settings
/// turns that off for whoever rebuilds often (a new host takes minutes with the folder, and extracting and translating every
/// shader again without it takes long).
///
/// What stays in either case is `BuildFolder`'s: logs/, profile/, run/, nsp/ and the staged inputs, which no part names.
///
/// For an iPhone or iPad build the game's framework (`shell-framework/DmGame<title ID>.framework`) lives in the build folder until the
/// installer mirrors it into the shell folder (`ShellInstall.mirrorFramework`). The mirror is the primary copy, so the folder is
/// removed only when the mirror is complete. Else the folder stays and the log says why. The Mac app holds everything itself.
enum BuildCleanup {
    static let defaultsKey = "keepBuildFiles"

    /// Off unless switched on in Settings.
    static func keepBuildFiles(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: defaultsKey) as? Bool ?? false }

    /// What the cleanup of one finished build needs to know, captured when the build's script succeeded.
    struct Plan: Equatable {
        var work: String
        var keepFiles: Bool
        /// Paths that stay wherever they lie: the finished app, the IPA, the game data archive, the installed app, the NSPs.
        var protecting: [String] = []
        /// An IPA exists outside the build folder, so what packing it left in ipa/ is not needed for it.
        var ipaWritten = false
        /// The game's framework in the shell folder, which must be complete before the build folder goes (iPhone and iPad). nil for the Mac app.
        var requiredMirror: String?
    }

    struct Outcome: Equatable {
        struct Item: Equatable { var part: BuildFolderPart?; var bytes: Int64 }
        /// What lost something, with the bytes each freed (`nil`: the scratch files that go whatever the setting says).
        var removed: [Item] = []
        var freed: Int64 = 0
        var failure: String?
        /// The mirror that was missing or incomplete, so the build folder was kept.
        var keptForMirror: String?
    }

    /// Whether a mirrored framework is a complete copy: the folder holds the framework's binary (`DmGame<title ID>`) and its manifest.
    nonisolated static func mirrorComplete(_ mirror: String, fm: FileManager = .default) -> Bool {
        let name = ((mirror as NSString).lastPathComponent as NSString).deletingPathExtension
        var isDir: ObjCBool = false
        func isFile(_ entry: String) -> Bool { fm.fileExists(atPath: mirror + "/" + entry, isDirectory: &isDir) && !isDir.boolValue }
        return !name.isEmpty && isFile(name) && isFile("game.manifest.json")
    }

    /// What is removed whatever the setting says, because nothing needs it after a successful build: the scratch folder, and
    /// the Payload folder and the copy of the IPA that packing an IPA once left in ipa/ (the script removes them itself on
    /// its next run, unless the copy is the IPA it wrote). Relative to the build folder.
    static func alwaysRemoved(ipaWritten: Bool) -> [String] {
        ["tmp"] + (ipaWritten ? ["ipa/build/ios/pkg/Payload", "ipa/build/ios/pkg/out.ipa", "ipa/build/ios/pkg/out.ipa.idx"] : [])
    }

    /// The parts that go when the files are not kept: every one the Free space sheet knows. The old shader versions are inside
    /// the shader output, and the script prunes them itself, so they are not asked for separately.
    static let partsWithoutKeeping: Set<BuildFolderPart> = [.extracted, .shaders, .xcode, .caches]

    /// What stays whole beyond the protected paths, relative to the build folder, for a plan.
    static func kept(_ plan: Plan, root: String) -> [String] {
        plan.protecting.filter { !$0.isEmpty }.map(BuildFolder.resolved)
    }

    /// Removes what the plan says. Off the main thread: it reads and deletes tens of GB.
    nonisolated static func run(_ plan: Plan) -> Outcome {
        let root = BuildFolder.resolved(plan.work)
        var outcome = Outcome()
        var isDir: ObjCBool = false
        guard root.hasSuffix("_build"), root.split(separator: "/").count > 1,
              FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return outcome }
        if !plan.keepFiles, let mirror = plan.requiredMirror, !mirrorComplete(mirror) {
            outcome.keptForMirror = mirror
            return outcome
        }
        let protecting = kept(plan, root: root)
        var failures: [String] = []

        var always: Int64 = 0
        for entry in alwaysRemoved(ipaWritten: plan.ipaWritten) where FileManager.default.fileExists(atPath: root + "/" + entry) {
            BuildFolder.removeTree(root + "/" + entry, protecting: protecting, freed: &always, failures: &failures)
        }
        if always > 0 { outcome.removed.append(.init(part: nil, bytes: always)) }
        outcome.freed += always

        if !plan.keepFiles {
            let before = BuildFolder.survey(root, protecting: protecting)
            do {
                let freed = try BuildFolder.remove(partsWithoutKeeping, in: root, protecting: protecting, buildRunning: false)
                outcome.freed += freed
                for part in BuildFolderPart.allCases where partsWithoutKeeping.contains(part) {
                    if let bytes = before.sizes[part], bytes > 0 { outcome.removed.append(.init(part: part, bytes: bytes)) }
                }
            } catch { failures.append(error.localizedDescription) }
        }
        outcome.failure = failures.first
        return outcome
    }

    /// The log's line for an outcome, nil when nothing was removed and nothing failed.
    static func logLines(_ outcome: Outcome, t: (String) -> String) -> [String] {
        var lines: [String] = []
        let names = outcome.removed.map { item in
            String(format: t("cleanup.item"), item.part.map { t("free.part." + $0.rawValue) } ?? t("cleanup.scratch"), FreeSpaceView.bytes(item.bytes))
        }
        if !names.isEmpty {
            lines.append(String(format: t("cleanup.removed"), names.joined(separator: ", "), FreeSpaceView.bytes(outcome.freed)))
        }
        if let mirror = outcome.keptForMirror { lines.append(String(format: t("cleanup.keptNoMirror"), mirror)) }
        if let failure = outcome.failure { lines.append(String(format: t("free.failed"), failure)) }
        return lines
    }

    /// Whether a build of this game starts from nothing: it was built before (an app, an IPA or its game data are there) and its
    /// build folder holds neither the extracted game files nor the shaders. The first build of a game says nothing.
    nonisolated static func rebuildsFromScratch(work: String, outputs: [String]) -> Bool {
        let fm = FileManager.default
        guard outputs.contains(where: { fm.fileExists(atPath: $0) }) else { return false }
        func filled(_ name: String) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: work + "/" + name)) ?? []).contains { !$0.hasPrefix(".") }
        }
        return !filled("extract") && !filled("shader")
    }
}

/// The launcher's side of it: arm the cleanup when the script succeeded, run it once the whole build has (the archive step and an
/// install on a device come after the script), never for a failed or stopped build.
extension BuildModel {
    /// Called when the build script exited with success. Nothing is removed yet: the Mac app, the archive and the install still read the folder.
    func armCleanup() {
        guard !effectiveWorkDir.isEmpty else { return }
        let baseDir = (basePath as NSString).deletingLastPathComponent
        let out = outDir.isEmpty ? baseDir : outDir
        let tid = Self.titleID(basePath).map { String(format: "%016llX", $0) } ?? "game"
        cleanupPlan = BuildCleanup.Plan(
            work: effectiveWorkDir, keepFiles: keepBuildFiles,
            protecting: BuildFolder.protectedPaths(app: macAppPath, ipa: "", iosApp: installedAppPath, archive: out + "/games/" + tid,
                                                   output: out, titleID: tid, inputs: slots.flatMap { $0.paths })
                + [out + "/" + tid + ".app", out + "/" + tid + ".ipa"],
            requiredMirror: target == BuildTarget.mac ? nil : ShellInstall.mirroredFramework(root: shellRoot, titleID: Self.buildKey(basePath)))
    }

    /// Called whenever `running` turns false. The build may go on in the next step (it turns true again at once), so the decision waits one turn.
    func scheduleCleanup() {
        guard cleanupPlan != nil else { return }
        DispatchQueue.main.async { [self] in
            guard var plan = cleanupPlan, !running else { return }
            cleanupPlan = nil
            guard done, !stopping else { return }   // a failed or stopped build keeps everything, and so does a failed install
            plan.protecting.append(installedAppPath)
            cleaningUp = true
            DispatchQueue.global(qos: .utility).async {
                let outcome = BuildCleanup.run(plan)
                DispatchQueue.main.async { [self] in
                    cleaningUp = false
                    for line in BuildCleanup.logLines(outcome, t: t) { say(line) }
                }
            }
        }
    }

    /// True when the next build of the game on the Build page extracts and translates again: it was built before and its build folder is gone.
    var rebuildFromScratch: Bool {
        guard !running, !cleaningUp, let tid = Self.titleID(basePath).map({ String(format: "%016llX", $0) }) else { return false }
        let out = outDir.isEmpty ? (basePath as NSString).deletingLastPathComponent : outDir
        return BuildCleanup.rebuildsFromScratch(work: out + "/" + tid + "_build",
                                                outputs: [out + "/" + tid + ".app", out + "/" + tid + ".ipa", out + "/games/" + tid + "/romfs.img"])
    }
}
