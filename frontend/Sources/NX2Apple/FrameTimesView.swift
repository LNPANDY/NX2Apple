import Charts
import SwiftUI

/// One recording (FrameTimes.swift): its numbers in a line and its frame times over the session, the hitches marked.
/// A recording can be several MB, so it is read and counted off the main thread (FrameTimesChart): the launch options
/// sheet opens at once, and the chart fills in when the numbers are ready.
struct FrameTimesRecordingView: View {
    let file: URL
    let t: (String) -> String
    @State private var chart: FrameTimesChart?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(file.deletingPathExtension().lastPathComponent).font(.manrope(13, .medium))
                Spacer()
            }
            if let chart {
                if let s = chart.summary {
                    Text(String(format: t("launch.frameTimesSummary"), s.frames, s.fps, s.frameP50, s.frameP99, s.frameMax, s.hitches, s.dropped))
                        .font(.manrope(12)).foregroundStyle(.secondary).monospacedDigit()
                    Chart {
                        ForEach(chart.line, id: \.number) { f in
                            LineMark(x: .value("s", f.time), y: .value("ms", f.frameMs)).interpolationMethod(.linear)
                        }
                        ForEach(chart.hitches, id: \.number) { f in
                            PointMark(x: .value("s", f.time), y: .value("ms", f.frameMs)).foregroundStyle(.red).symbolSize(14)
                        }
                        RuleMark(y: .value("ms", s.frameP50)).foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    .chartXScale(domain: chart.timeSpan)
                    .chartXAxisLabel("s").chartYAxisLabel("ms")
                    .frame(height: 120)
                } else {
                    Text(t("launch.frameTimesEmpty")).font(.manrope(12)).foregroundStyle(.secondary)
                }
            } else {
                // While the file is read: the summary line's and the chart's room, so nothing moves when they arrive
                Text(" ").font(.manrope(12))
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 120)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .task(id: file) {
            chart = nil
            let file = file
            chart = await Task.detached(priority: .userInitiated) { FrameTimesChart(file: file) }.value
        }
    }
}

/// What the chart of one recording draws, worked out once from the file.
struct FrameTimesChart {
    let summary: FrameTimes.Summary?
    let line: [FrameTimes.Frame]
    let hitches: [FrameTimes.Frame]
    let timeSpan: ClosedRange<Double>

    init(file: URL) { self.init(frames: FrameTimes.parse((try? String(contentsOf: file, encoding: .utf8)) ?? "")) }

    init(frames: [FrameTimes.Frame]) {
        summary = FrameTimes.Summary(frames)
        line = Self.thinned(frames)
        hitches = frames.filter { $0.frameMs > FrameTimes.Summary.hitchMs }
        let first = frames.first?.time ?? 0
        timeSpan = first...max(frames.last?.time ?? 1, first + 1)
    }

    /// At most about 2,000 points on the line (a long session has hundreds of thousands of frames): every n-th frame,
    /// each one the slowest of its stretch, so a hitch is never thinned away.
    static func thinned(_ frames: [FrameTimes.Frame]) -> [FrameTimes.Frame] {
        let step = max(1, frames.count / 2000)
        guard step > 1 else { return frames }
        return stride(from: 0, to: frames.count, by: step).map { i in
            frames[i..<min(frames.count, i + step)].max { $0.frameMs < $1.frameMs }!
        }
    }
}
