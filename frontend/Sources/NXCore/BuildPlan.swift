import Foundation

/// Inputs known at the moment a build starts so the launcher can show the full expected stage plan from the beginning.
package struct BuildPlanInput: Sendable {
    package var upstream: EngineUpstreamKind
    package var target: String
    package var fastRefresh: Bool
    package var exportsOneGame: Bool
    package var exportsFramework: Bool
    package var exportsShell: Bool
    package var deviceName: String
    package var preflightEnabled: Bool
    package var isGameFolder: Bool
    package var isNUP: Bool
    package var hasDLC: Bool
    package var titleID: String?
    package var engineRoot: String
    package var canPackS2ArmMacApp: Bool
    package var includeDeviceCopyStage: Bool

    package init(
        upstream: EngineUpstreamKind = .nxnative,
        target: String = BuildTarget.mac,
        fastRefresh: Bool = false,
        exportsOneGame: Bool = false,
        exportsFramework: Bool = false,
        exportsShell: Bool = false,
        deviceName: String = "",
        preflightEnabled: Bool = true,
        isGameFolder: Bool = false,
        isNUP: Bool = false,
        hasDLC: Bool = false,
        titleID: String? = nil,
        engineRoot: String = "",
        canPackS2ArmMacApp: Bool = false,
        includeDeviceCopyStage: Bool = true
    ) {
        self.upstream = upstream
        self.target = target
        self.fastRefresh = fastRefresh
        self.exportsOneGame = exportsOneGame
        self.exportsFramework = exportsFramework
        self.exportsShell = exportsShell
        self.deviceName = deviceName
        self.preflightEnabled = preflightEnabled
        self.isGameFolder = isGameFolder
        self.isNUP = isNUP
        self.hasDLC = hasDLC
        self.titleID = titleID
        self.engineRoot = engineRoot
        self.canPackS2ArmMacApp = canPackS2ArmMacApp
        self.includeDeviceCopyStage = includeDeviceCopyStage
    }
}

/// Builds and reconciles the full expected stage list (`1..<1000` script stages, `1000...` post-build stages) so the
/// progress bar and steps sheet know every step ahead from the start and update cleanly as runtime stages arrive.
package enum BuildPlan {
    package enum ProfileGraphics: Equatable, Sendable {
        case nvn(hasGLSLCCapture: Bool)
        case gl(needsCapture: Bool)
        case vulkan(needsCapture: Bool)
    }

    package enum CanonicalKind: Equatable, Sendable {
        case prep
        case extract
        case extractDLC
        case checkFiles
        case rewrite
        case nroCapture
        case heapCheck
        case addressRegions
        case glslcCapture
        case ueDecode
        case glCapture
        case vkCapture
        case shaderSplit
        case macShaders
        case iosShaders
        case glShaders
        case vulkanShaders
        case jitCapture
        case macHost
        case macApp
        case gameFramework
        case appBuild
        case ipaPack
        case pipelineArchive
        case preflight
        case other(String)
    }

    /// Inspects `<engineRoot>/dm/games/<TID>/` (when present) to infer graphics API and capture steps without running Python.
    package static func inspectProfile(
        titleID: String?,
        engineRoot: String,
        fileManager fm: FileManager = .default
    ) -> ProfileGraphics {
        guard !engineRoot.isEmpty,
              let raw = titleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.count == 16,
              UInt64(raw, radix: 16) != nil else {
            return .nvn(hasGLSLCCapture: false)
        }
        let profileDir = engineRoot + "/dm/games/" + raw.uppercased()
        if fm.fileExists(atPath: profileDir + "/gl_capture.tsv") {
            return .gl(needsCapture: true)
        }
        if fm.fileExists(atPath: profileDir + "/vk_capture.tsv") {
            return .vulkan(needsCapture: true)
        }
        if let text = try? String(contentsOfFile: profileDir + "/game.tsv", encoding: .utf8) {
            let lower = text.lowercased()
            if lower.contains("gl_shaders.py") || lower.contains("the gl layer") || lower.contains("gl layer") {
                return .gl(needsCapture: false)
            }
            if lower.contains("vk_shaders.py") || lower.contains("the vulkan layer") || lower.contains("vulkan layer") {
                return .vulkan(needsCapture: false)
            }
        }
        return .nvn(hasGLSLCCapture: false)
    }

    /// Initial full list of `.pending` stages before the build process begins printing lines.
    package static func initialStages(
        for input: BuildPlanInput,
        localizedName: (String) -> String = { $0 },
        fileManager fm: FileManager = .default
    ) -> [Stage] {
        let isMac = BuildTarget.normalized(input.target) == BuildTarget.mac
        var scriptNames: [String] = []

        switch input.upstream {
        case .nxkit:
            scriptNames = [
                input.isNUP ? "NUP and shader split" : "packages and shader split",
                "rewrite",
                "shaders and pipeline archive",
                "bundle"
            ]
        case .macNativeGames:
            scriptNames = ["1/4 code", "2/4 data", "3/4 shaders", "4/4 app"]
        case .s2arm:
            if isMac && input.canPackS2ArmMacApp {
                scriptNames = ["Mac app"]
            }
        case .nxnative, .kidWithSword, .noLagKart:
            let gfx = inspectProfile(titleID: input.titleID, engineRoot: input.engineRoot, fileManager: fm)
            if !input.fastRefresh {
                if input.isNUP {
                    scriptNames.append("unpack")
                } else if input.isGameFolder {
                    scriptNames.append("pack")
                } else {
                    scriptNames.append("extract")
                }
                if input.hasDLC {
                    if input.isNUP {
                        scriptNames.append("unpack DLC")
                    } else if input.isGameFolder {
                        scriptNames.append("pack DLC")
                    } else {
                        scriptNames.append("extract DLC")
                    }
                }
                scriptNames.append("rewrite")
            }
            switch gfx {
            case .gl(let needsCapture):
                if !input.fastRefresh && needsCapture {
                    scriptNames.append("GL shader capture")
                }
                scriptNames.append("GL shaders")
            case .vulkan(let needsCapture):
                if !input.fastRefresh && needsCapture {
                    scriptNames.append("Vulkan shader capture")
                }
                scriptNames.append("Vulkan shaders")
            case .nvn(let hasGLSLC):
                if !input.fastRefresh && hasGLSLC {
                    scriptNames.append("GLSLC capture")
                }
                scriptNames.append("shader split")
                scriptNames.append(isMac ? "Mac shaders" : "iOS shaders")
            }
            if isMac {
                scriptNames.append("Mac host")
                scriptNames.append("Mac app")
            } else if input.exportsOneGame {
                scriptNames.append("app build")
                scriptNames.append("IPA pack")
            } else {
                scriptNames.append("game framework")
            }
        }

        var stages: [Stage] = scriptNames.enumerated().map { index, name in
            Stage(id: index + 1, name: name, state: .pending)
        }

        if isMac {
            if input.preflightEnabled {
                stages.append(Stage(id: 1000, name: "preflight", state: .pending, nameKey: "stage.preflight"))
            }
        } else if !input.exportsOneGame && !input.exportsFramework {
            let dev = input.deviceName
            if input.exportsShell {
                stages.append(Stage(id: ShellInstaller.projectStageID, name: localizedName("shell.projectStage"), state: .pending,
                                    nameKey: "shell.projectStage"))
                stages.append(Stage(id: ShellInstaller.exportBuildStageID, name: localizedName("shell.exportBuildStage"), state: .pending,
                                    nameKey: "shell.exportBuildStage"))
                stages.append(Stage(id: ShellInstaller.exportPackStageID, name: localizedName("shell.exportPackStage"), state: .pending,
                                    nameKey: "shell.exportPackStage"))
            } else {
                func fmt(_ key: String) -> String {
                    let f = localizedName(key)
                    return dev.isEmpty ? f : String(format: f, dev)
                }
                stages.append(Stage(id: ShellInstaller.projectStageID, name: localizedName("shell.projectStage"), state: .pending,
                                    nameKey: "shell.projectStage"))
                stages.append(Stage(id: ShellInstaller.signStageID, name: fmt("dev.signStage"), state: .pending,
                                    nameKey: "dev.signStage", nameArgument: dev.isEmpty ? nil : dev))
                stages.append(Stage(id: ShellInstaller.installStageID, name: fmt("dev.installStage"), state: .pending,
                                    nameKey: "dev.installStage", nameArgument: dev.isEmpty ? nil : dev))
                stages.append(Stage(id: ShellInstaller.checkStageID, name: fmt("shell.checkStage"), state: .pending,
                                    nameKey: "shell.checkStage", nameArgument: dev.isEmpty ? nil : dev))
                if input.includeDeviceCopyStage {
                    stages.append(Stage(id: ShellInstaller.copyStageID, name: fmt("dev.copyStage"), state: .pending,
                                        nameKey: "dev.copyStage", nameArgument: dev.isEmpty ? nil : dev))
                }
            }
        }

        return stages
    }

    /// Maps a script stage name to its canonical family so predicted `.pending` rows align with runtime names like `"extract v851968"`.
    package static func canonicalKind(of name: String) -> CanonicalKind {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "decompress nsz" || lower == "build id lookup" || lower.hasPrefix("survey:") {
            return .prep
        }
        if lower == "extract dlc" || lower == "unpack dlc" || lower == "pack dlc" {
            return .extractDLC
        }
        if lower.hasPrefix("check ") && lower.hasSuffix(" files") {
            return .checkFiles
        }
        if lower == "extract" || lower.hasPrefix("extract ")
            || lower == "unpack" || lower.hasPrefix("unpack ")
            || lower == "pack" || lower.hasPrefix("pack ") {
            return .extract
        }
        if lower == "rewrite" { return .rewrite }
        if lower == "nro capture" { return .nroCapture }
        if lower == "heap check" { return .heapCheck }
        if lower == "address regions" { return .addressRegions }
        if lower == "glslc capture" { return .glslcCapture }
        if lower == "ue shader decode" { return .ueDecode }
        if lower == "gl shader capture" { return .glCapture }
        if lower == "vulkan shader capture" { return .vkCapture }
        if lower == "shader split" { return .shaderSplit }
        if lower == "mac shaders" { return .macShaders }
        if lower == "ios shaders" { return .iosShaders }
        if lower == "gl shaders" { return .glShaders }
        if lower == "vulkan shaders" { return .vulkanShaders }
        if lower == "jit capture" { return .jitCapture }
        if lower == "mac host" { return .macHost }
        if lower == "mac app" { return .macApp }
        if lower == "game framework" { return .gameFramework }
        if lower == "app build" { return .appBuild }
        if lower == "ipa pack" { return .ipaPack }
        if lower == "pipeline archive" || lower == "pipeline prebuild" || lower == "prewarm pipelines" {
            return .pipelineArchive
        }
        if lower == "preflight" || lower == "verify first start" {
            return .preflight
        }
        return .other(lower)
    }

    /// Replaces unstarted script stages (`id < 1000`) with an explicit `{"ev":"plan","stages":[...]}` list from the script.
    package static func applyScriptPlan(_ names: [String], to stages: inout [Stage]) {
        guard !names.isEmpty else { return }
        let prep = stages.filter { $0.id <= 0 }
        let startedScript = stages.filter { $0.id > 0 && $0.id < 1000 && $0.state != .pending }
        let post = stages.filter { $0.id >= 1000 }
        var mergedScript = startedScript
        for (idx, rawName) in names.enumerated() {
            let stageID = idx + 1
            if mergedScript.contains(where: { $0.id == stageID }) { continue }
            mergedScript.append(Stage(id: stageID, name: rawName, state: .pending))
        }
        mergedScript.sort { $0.id < $1.id }
        stages = prep + mergedScript + post
    }

    /// Reconciles an incoming script stage `(k, name)` against pre-seeded `.pending` stages without losing future steps.
    package static func upsertScriptStage(
        k: Int,
        name: String,
        state: StepState,
        detail: String,
        percent: Double?,
        started: Date?,
        into stages: inout [Stage]
    ) {
        let incomingKind = canonicalKind(of: name)
        var prep = stages.filter { $0.id <= 0 }
        var script = stages.filter { $0.id > 0 && $0.id < 1000 }.sorted { $0.id < $1.id }
        let post = stages.filter { $0.id >= 1000 }

        // Pre-plan stages (`decompress NSZ`, `build ID lookup`, `survey: ...`) run with k=1..3 before main `PROG.plan(...)`
        // resets k=1 at `extract`. Archive completed prep stages to negative IDs so main stage 1 aligns cleanly.
        if k == 1,
           state == .running,
           let existingOne = script.first(where: { $0.id == 1 }),
           existingOne.state != .pending,
           canonicalKind(of: existingOne.name) != incomingKind,
           canonicalKind(of: existingOne.name) == .prep {
            let nextPrepID = (prep.map(\.id).max() ?? -100) + 1
            let archived = Stage(
                id: min(0, nextPrepID), name: existingOne.name, state: existingOne.state, detail: existingOne.detail,
                percent: existingOne.percent, started: existingOne.started, eta: existingOne.eta, etaAt: existingOne.etaAt,
                nameKey: existingOne.nameKey, nameArgument: existingOne.nameArgument, weight: existingOne.weight
            )
            prep.append(archived)
            script.removeAll { $0.id == 1 }
            for idx in script.indices where script[idx].id > 1 && script[idx].state == .pending {
                let s = script[idx]
                script[idx] = Stage(
                    id: s.id - 1, name: s.name, state: s.state, detail: s.detail, percent: s.percent,
                    started: s.started, eta: s.eta, etaAt: s.etaAt, nameKey: s.nameKey, nameArgument: s.nameArgument, weight: s.weight
                )
            }
        }

        // If a provisional build predicted NVN (`shader split` + `Mac/iOS shaders`) but runtime enters GL or Vulkan capture,
        // swap pending NVN shader stages for the real GL/Vulkan shader stage.
        if incomingKind == .glCapture {
            script = replacePendingShaderPlan(in: script, with: "GL shaders", afterID: k)
        } else if incomingKind == .vkCapture {
            script = replacePendingShaderPlan(in: script, with: "Vulkan shaders", afterID: k)
        }

        if let exactIndex = script.firstIndex(where: { $0.id == k }) {
            let existing = script[exactIndex]
            let existingKind = canonicalKind(of: existing.name)
            if existing.state != .pending || existingKind == incomingKind || incomingKind == .other(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                // Exact ID match (either active/done update, or matching pending stage).
                if !name.isEmpty {
                    script[exactIndex].name = name
                    script[exactIndex].weight = BuildProgress.stageWeight(name: name, nameKey: script[exactIndex].nameKey)
                }
                if state != .pending { script[exactIndex].state = state }
                if !detail.isEmpty { script[exactIndex].detail = detail }
                if let percent { script[exactIndex].percent = percent }
                if state == .running, script[exactIndex].started == nil { script[exactIndex].started = started ?? Date() }
                stages = prep.sorted { $0.id < $1.id } + script.sorted { $0.id < $1.id } + post
                return
            }
            // `existing` at id == k is a different `.pending` stage: either a predicted stage was skipped, or a new stage was inserted.
            if let laterMatch = script.firstIndex(where: { $0.id > k && $0.state == .pending && canonicalKind(of: $0.name) == incomingKind }) {
                let matchedID = script[laterMatch].id
                let delta = matchedID - k
                // Drop skipped pending stages between k and matchedID, then pull matched & later pending stages forward.
                script.removeAll { $0.id >= k && $0.id < matchedID && $0.state == .pending }
                for idx in script.indices where script[idx].id >= matchedID && script[idx].state == .pending {
                    let s = script[idx]
                    let newID = s.id - delta
                    script[idx] = Stage(
                        id: newID, name: newID == k && !name.isEmpty ? name : s.name,
                        state: newID == k ? state : s.state,
                        detail: newID == k ? detail : s.detail,
                        percent: newID == k ? percent : s.percent,
                        started: newID == k && state == .running ? (started ?? Date()) : s.started,
                        eta: s.eta, etaAt: s.etaAt, nameKey: s.nameKey, nameArgument: s.nameArgument,
                        weight: newID == k && !name.isEmpty ? BuildProgress.stageWeight(name: name, nameKey: s.nameKey) : s.weight
                    )
                }
                stages = prep.sorted { $0.id < $1.id } + script.sorted { $0.id < $1.id } + post
                return
            }
            // Newly discovered dynamic stage (e.g. second extract version, NRO capture, heap check, Pipeline archive):
            // shift pending script stages at >= k by +1 and insert at k.
            for idx in script.indices where script[idx].id >= k && script[idx].state == .pending {
                let s = script[idx]
                script[idx] = Stage(
                    id: s.id + 1, name: s.name, state: s.state, detail: s.detail, percent: s.percent,
                    started: s.started, eta: s.eta, etaAt: s.etaAt, nameKey: s.nameKey, nameArgument: s.nameArgument, weight: s.weight
                )
            }
            if state != .pending {
                script.append(Stage(id: k, name: name, state: state, detail: detail, percent: percent, started: started ?? Date()))
            }
        } else if state != .pending {
            script.append(Stage(id: k, name: name, state: state, detail: detail, percent: percent, started: started ?? Date()))
        }

        stages = prep.sorted { $0.id < $1.id } + script.sorted { $0.id < $1.id } + post
    }

    private static func replacePendingShaderPlan(in script: [Stage], with replacement: String, afterID k: Int) -> [Stage] {
        var out: [Stage] = []
        var replaced = false
        var shift = 0
        for s in script {
            let kind = canonicalKind(of: s.name)
            if s.id >= k && s.state == .pending && (kind == .shaderSplit || kind == .macShaders || kind == .iosShaders) {
                if !replaced {
                    replaced = true
                    out.append(Stage(id: s.id, name: replacement, state: .pending))
                } else {
                    shift += 1
                }
                continue
            }
            if shift > 0 && s.state == .pending {
                out.append(Stage(id: s.id - shift, name: s.name, state: s.state, detail: s.detail, percent: s.percent,
                                 started: s.started, eta: s.eta, etaAt: s.etaAt, nameKey: s.nameKey, nameArgument: s.nameArgument, weight: s.weight))
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// Marks script stages (`id < 1000`) done when the build script finishes, dropping un-run `.pending` script stages while
    /// keeping post-build `.pending` stages (`id >= 1000`, e.g. `preflight`, `Sign`, `Install`) intact.
    package static func markScriptStagesDone(in stages: inout [Stage]) {
        stages.removeAll { $0.id < 1000 && $0.state == .pending }
        for idx in stages.indices where stages[idx].id < 1000 && stages[idx].state != .failed {
            stages[idx].state = .done
            stages[idx].percent = 100
        }
    }

    /// Drops any remaining `.pending` post-build stages when the entire build finishes (e.g. skipped data copy or disabled preflight).
    package static func pruneUnrunPendingStages(in stages: inout [Stage]) {
        stages.removeAll { $0.state == .pending }
        for idx in stages.indices where stages[idx].state == .running {
            stages[idx].state = .done
            stages[idx].percent = 100
        }
    }
}
