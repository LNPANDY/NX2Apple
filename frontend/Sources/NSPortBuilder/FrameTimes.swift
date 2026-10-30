import Foundation

// Frame-time recordings from the launcher. The host already writes a timing row per frame when DM_NVN_TSV names a file
// (dm/gfx/nvn/hle_nvn.c, the rows scripts/bench.py reads); this is that switch for players: on in a game's launch options,
// Play passes DM_NVN_TSV (with DM_NVN_TSV_CALLS=0, timing rows only) to a new file in <library>/frame-times/<title ID>/,
// and the launch options sum the recordings up and chart them, so a stutter or a slow place can be seen and reported
// without the command line. The numbers are counted as bench.py counts them (nearest-rank percentiles).

enum FrameTimes {
    /// One frame's timing rows: @t_s (seconds from the start), @frame_ms (start to start), @presented_ms (on screen;
    /// -1 when the frame was never shown), @gpu_ms.
    struct Frame: Equatable {
        var number: Int
        var time: Double
        var frameMs: Double
        var presentedMs: Double?
        var gpuMs: Double?
    }

    /// The frames of a recording that have a time and a frame time, in frame order; other rows (the call counts, a line
    /// the host is still writing) are skipped.
    static func parse(_ text: String) -> [Frame] {
        var rows: [Int: [String: Double]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard c.count == 3, c[1].hasPrefix("@"), let n = Int(c[0].trimmingCharacters(in: .whitespaces)),
                  let v = Double(c[2].trimmingCharacters(in: .whitespaces)) else { continue }
            rows[n, default: [:]][String(c[1])] = v
        }
        return rows.keys.sorted().compactMap { n in
            let r = rows[n]!
            guard let t = r["@t_s"], let f = r["@frame_ms"] else { return nil }
            return Frame(number: n, time: t, frameMs: f, presentedMs: r["@presented_ms"], gpuMs: r["@gpu_ms"])
        }
    }

    /// Nearest-rank percentile, as scripts/bench.py's pct.
    static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s[min(s.count - 1, max(0, Int((p / 100 * Double(s.count)).rounded(.up)) - 1))]
    }

    struct Summary: Equatable {
        static let hitchMs = 50.0   // a frame this long is felt as a hitch
        var frames, dropped, hitches: Int
        var seconds, frameP50, frameP95, frameP99, frameMax: Double
        var fps: Double { seconds > 0 ? Double(frames) / seconds : 0 }

        init?(_ frames: [Frame]) {
            let ft = frames.map(\.frameMs).filter { $0 > 0 }
            guard let first = frames.first, let last = frames.last, !ft.isEmpty else { return nil }
            self.frames = frames.count
            dropped = frames.filter { $0.presentedMs == -1 }.count
            hitches = ft.filter { $0 > Self.hitchMs }.count
            seconds = last.time - first.time
            frameP50 = FrameTimes.percentile(ft, 50)!
            frameP95 = FrameTimes.percentile(ft, 95)!
            frameP99 = FrameTimes.percentile(ft, 99)!
            frameMax = ft.max()!
        }
    }

    /// What Play passes for a recording: the file, and timing rows only (the call-count rows make the file large).
    static func environment(recordTo file: URL?) -> [String: String] {
        guard let file else { return [:] }
        return ["DM_NVN_TSV": file.path, "DM_NVN_TSV_CALLS": "0"]
    }

    /// What Play adds for a game whose recording is on (a new file in its folder), whichever way it starts: the desktop
    /// Play (LauncherView) and console mode (LiveConsoleDriver) both call this. Empty while off, or when the folder cannot be made.
    static func recordingEnvironment(for game: LibraryGame, library: String) -> [String: String] {
        guard enabled(titleID: game.titleID) else { return [:] }
        return environment(recordTo: try? newRecording(in: folder(titleID: game.titleID, library: library)))
    }

    /// A game's recordings, beside its mods (GameMod.folder).
    static func folder(titleID: String, library: String) -> URL {
        let root = library.isEmpty
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NS Port Builder")
            : URL(fileURLWithPath: library)
        return root.appendingPathComponent("frame-times").appendingPathComponent(titleID)
    }

    /// The file for a new recording, named by its start time; the folder is made.
    static func newRecording(in folder: URL, at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return folder.appendingPathComponent(f.string(from: date)).appendingPathExtension("tsv")
    }

    /// The recordings in a folder, newest first.
    static func recordings(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "tsv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func defaultsKey(titleID: String) -> String { "recordFrameTimes." + titleID }
    /// Off unless switched on for the game.
    static func enabled(titleID: String) -> Bool { UserDefaults.standard.bool(forKey: defaultsKey(titleID: titleID)) }
    static func setEnabled(_ on: Bool, titleID: String) { UserDefaults.standard.set(on, forKey: defaultsKey(titleID: titleID)) }
}
