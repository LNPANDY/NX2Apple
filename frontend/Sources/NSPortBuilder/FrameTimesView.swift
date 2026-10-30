import Charts
import SwiftUI

/// One recording (FrameTimes.swift): its numbers in a line and its frame times over the session, the hitches marked.
struct FrameTimesRecordingView: View {
    let file: URL
    let t: (String) -> String
    @State private var frames: [FrameTimes.Frame] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(file.deletingPathExtension().lastPathComponent).font(.manrope(13, .medium))
                Spacer()
            }
            if let s = FrameTimes.Summary(frames) {
                Text(String(format: t("launch.frameTimesSummary"), s.frames, s.fps, s.frameP50, s.frameP99, s.frameMax, s.hitches, s.dropped))
                    .font(.manrope(12)).foregroundStyle(.secondary).monospacedDigit()
                Chart {
                    ForEach(thinned, id: \.number) { f in
                        LineMark(x: .value("s", f.time), y: .value("ms", f.frameMs)).interpolationMethod(.linear)
                    }
                    ForEach(frames.filter { $0.frameMs > FrameTimes.Summary.hitchMs }, id: \.number) { f in
                        PointMark(x: .value("s", f.time), y: .value("ms", f.frameMs)).foregroundStyle(.red).symbolSize(14)
                    }
                    RuleMark(y: .value("ms", s.frameP50)).foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartXScale(domain: (frames.first?.time ?? 0)...max((frames.last?.time ?? 1), (frames.first?.time ?? 0) + 1))
                .chartXAxisLabel("s").chartYAxisLabel("ms")
                .frame(height: 120)
            } else {
                Text(t("launch.frameTimesEmpty")).font(.manrope(12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .task(id: file) { frames = FrameTimes.parse((try? String(contentsOf: file, encoding: .utf8)) ?? "") }
    }

    /// At most about 2,000 points on the line (a long session has hundreds of thousands of frames): every n-th frame,
    /// each one the slowest of its stretch, so a hitch is never thinned away.
    private var thinned: [FrameTimes.Frame] {
        let step = max(1, frames.count / 2000)
        guard step > 1 else { return frames }
        return stride(from: 0, to: frames.count, by: step).map { i in
            frames[i..<min(frames.count, i + step)].max { $0.frameMs < $1.frameMs }!
        }
    }
}
