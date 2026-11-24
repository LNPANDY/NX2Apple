import Foundation
import NXCore

extension BuildStore {
    static func isPSOStage(_ name: String) -> Bool {
        name == "Pipeline archive" || name == "game framework"
    }

    // MARK: Output parsing

    package func say(_ s: String) { append(s + "\n") }
    package func append(_ s: String) { log.append(s) }

    /// Split into lines (the pipe delivers arbitrary chunks) and turn the script's progress into the stage list.
    /// `--progress json` writes one event per line (plan, stage, step, progress with done / total / frac / eta,
    /// stage_end, say), a count change at most every half second, and anything else on the pipe is log text.
    package func ingest(_ chunk: String) {
        for line in log.feed(chunk) { handle(line) }
    }

    package func flushLines() {
        if let rest = log.flush() { handle(rest) }
    }

    package func handle(_ line: String) {
        if line.hasPrefix("{"), let data = line.data(using: .utf8),
           let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let kind = event["ev"] as? String {
            return handleEvent(kind, event)
        }
        append(line + "\n")
        guard let s = BuildProgress.parseStageWithTotal(line) else {
            if mngRun || s2armRun { handleExternalUpstreamLogLine(line) }
            return
        }
        if s.state == .running {
            if Self.isPSOStage(s.name) {
                if s.percent != nil {
                    psoPollGeneration &+= 1
                    psoNativeProgress = true
                    psoPollTask?.cancel()
                    psoPollTask = nil
                } else if psoStageID != s.k {
                    startPSOPoll(stageID: s.k, step: "")
                }
            } else if psoStageID == s.k {
                stopPSOPoll()
            }
        } else if psoStageID == s.k {
            stopPSOPoll()
        }
        if s.state != .pending {
            BuildPlan.upsertScriptStage(
                k: s.k,
                name: s.name,
                state: s.state,
                detail: s.detail,
                percent: s.percent,
                started: Date(),
                into: &stages
            )
            if let i = stages.firstIndex(where: { $0.id == s.k }) {
                let keepPSOPoll = (s.state == .running && s.percent == nil && psoStageID == s.k && !psoNativeProgress && stages[i].percent != nil)
                if !keepPSOPoll {
                    stages[i].percent = s.percent
                }
            }
        }
        refreshOverallProgress(parsedTotal: s.n)
    }

    /// The `shaders_stale` event: the cached shader libraries cannot be reused and this build rebuilds them, because the
    /// shader translator changed (`reason` "chain") or the game profile's shader inputs did ("inputs").
    package func noteStaleShaders(reason: String) {
        activeRunRebuiltShaders = true
        guard let text = ["chain": "msg.shadersStale.chain", "inputs": "msg.shadersStale.inputs"][reason], staleShadersMessageKey == nil else { return }
        staleShadersMessageKey = text
    }

    /// One event of `--progress json`: the stage list follows it, and the log gets a readable line (no count updates).
    package func handleEvent(_ kind: String, _ e: [String: Any]) {
        if kind == "plan", let names = e["stages"] as? [String], !names.isEmpty {
            BuildPlan.applyScriptPlan(names, to: &stages)
            refreshOverallProgress(parsedTotal: names.count)
            return
        }
        let k = (e["k"] as? NSNumber)?.intValue ?? 0
        func stage(_ update: (inout Stage) -> Void) {
            if let i = stages.firstIndex(where: { $0.id == k }) {
                update(&stages[i])
            } else {
                var s = Stage(id: k, name: e["name"] as? String ?? "")
                update(&s)
                stages.append(s)
                stages.sort { $0.id < $1.id }
            }
        }
        switch kind {
        case "stage":
            let name = e["name"] as? String ?? "", step = e["step"] as? String ?? ""
            let n = (e["n"] as? NSNumber)?.intValue ?? 0
            append("[\(k)/\(n)] \(name)" + (step.isEmpty ? "" : " · \(step)") + " …\n")
            BuildPlan.upsertScriptStage(
                k: k,
                name: name,
                state: .running,
                detail: step,
                percent: nil,
                started: Date(),
                into: &stages
            )
            stage {
                $0.percent = nil
                $0.eta = nil
                $0.isScanningLastShaderFiles = false
            }
            if Self.isPSOStage(name) { startPSOPoll(stageID: k, step: step) }
            else if psoStageID == k { stopPSOPoll() }
            refreshOverallProgress(parsedTotal: n)
        case "step":
            let step = e["step"] as? String ?? ""
            append("    · \(step)\n")
            stage {
                $0.detail = step
                $0.percent = nil
                $0.eta = nil
                $0.isScanningLastShaderFiles = false
            }
            if step.hasPrefix("pipeline archive") { startPSOPoll(stageID: k, step: step) }
            else if psoStageID == k { stopPSOPoll() }
            refreshOverallProgress(parsedTotal: nil)
        case "progress":
            let fraction = (e["frac"] as? NSNumber)?.doubleValue
            let done = (e["done"] as? NSNumber)?.intValue
            if psoStageID == k, fraction != nil || done != nil {
                psoPollGeneration &+= 1
                psoNativeProgress = true
                psoPollTask?.cancel()
                psoPollTask = nil
            }
            let detail = BuildProgress.progressDetail(e)
            let eta = (e["eta"] as? NSNumber)?.doubleValue
            stage {
                $0.percent = fraction.map { $0 * 100 }
                $0.detail = detail
                $0.eta = eta
                $0.etaAt = eta == nil ? nil : Date()
                $0.isScanningLastShaderFiles = BuildProgress.isScanningLastShaderFiles(e)
            }
            refreshOverallProgress(parsedTotal: nil)
        case "stage_end":
            if psoStageID == k { stopPSOPoll() }
            let ok = e["ok"] as? Bool ?? true, summary = e["summary"] as? String ?? ""
            let elapsed = BuildProgress.duration((e["elapsed"] as? NSNumber)?.doubleValue ?? 0)
            append("\(ok ? "✓" : "✗") \(e["name"] as? String ?? "") (\(elapsed))" + (summary.isEmpty ? "" : ": \(summary)") + "\n")
            stage {
                $0.state = ok ? .done : .failed
                $0.detail = summary
                $0.percent = ok ? 100 : $0.percent
                $0.eta = nil
                $0.isScanningLastShaderFiles = false
            }
            refreshOverallProgress(parsedTotal: nil)
        case "say":
            let msg = e["msg"] as? String ?? ""
            append(msg + "\n")
        case "shaders_stale":
            noteStaleShaders(reason: e["reason"] as? String ?? "")
        default: break
        }
    }
}
