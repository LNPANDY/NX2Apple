import SwiftUI

/// "A new version is out", with what it changes, shown when the app opens or Check for updates finds
/// one. The app already had the update machinery (checkAppUpdate / performAppUpdate); what it lacked
/// was a reason to press the button: the status line said a tag name and nothing else, and a user who
/// was working fine had no way to tell whether the new version mattered to them.
///
/// The notes come from the release body, which this project writes in both languages (see
/// docs/RELEASE-NOTES-GUIDE.md). The sheet does not try to translate them; it shows the lines that
/// match the interface language and falls back to the whole body when it cannot tell them apart.
struct UpdateSheet: View {
    @ObservedObject var m: BuildModel
    @Environment(\.dismiss) private var dismiss

    private var update: AppUpdate.Release? { m.appUpdate }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(m.t("update.title"))
                    .font(.manrope(24, .heavy)).tracking(-0.5)
                Text(String(format: m.t("update.fromTo"), BuildModel.appVersion, update?.tag ?? ""))
                    .font(.manrope(13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let notes = update?.notes, !notes.isEmpty {
                        ForEach(Array(Self.lines(notes, for: m.lang).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.manrope(13))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text(m.t("update.noNotes")).font(.manrope(13)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
            }
            .frame(maxHeight: 340)

            if let blocked = m.appUpdateBlocked {
                Text(blocked).font(.manrope(12.5)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28).padding(.bottom, 12)
            }
            Divider().opacity(0.3)
            HStack(spacing: 12) {
                if let u = update {
                    Link(m.t("update.openPage"), destination: URL(string: "https://github.com/LNPANDY/NX2Apple/releases/tag/\(u.tag)")!)
                        .font(.manrope(12.5))
                }
                Spacer(minLength: 8)
                Button(m.t("update.later")) { dismiss() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    // Automatic mode has already downloaded and staged the release, so the action is
                    // to swap it in now; otherwise this downloads, verifies and installs as before.
                    // The sheet stays up while it downloads, so a refusal (a macOS too old for the release) is seen here.
                    if m.appStaged != nil { m.installStagedUpdate(relaunch: true); dismiss() } else { m.performAppUpdate() }
                } label: {
                    Text(m.t(m.appStaged != nil ? "app.restartNow" : "update.now"))
                        .font(.manrope(13.5, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(m.appBusy)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(width: 560)
        .background(LauncherPalette.background)
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
    }

    /// The release body's lines for one language.
    ///
    /// Two shapes are in the wild, both described in docs/RELEASE-NOTES-GUIDE.md:
    ///
    /// * **Current**: English written out in full, `---`, then Chinese in full. The `---` is the
    ///   split, so the two halves are read straight through and neither reader sees the other's text.
    /// * **Older releases (0.4.7 and before)**: `**中文** …` and `**English** …` paragraphs with the
    ///   bullet lists interleaved one line each. Those are split on the markers.
    ///
    /// A body with neither is shown whole — splitting it by guesswork is how the first version gave
    /// an English reader the Chinese paragraph (that line contains both scripts).
    static func lines(_ notes: String, for lang: Lang) -> [String] {
        // Shape 1: two halves around a `---` line.
        let halves = notes.components(separatedBy: "\n---\n")
        if halves.count == 2 {
            let first = clean(halves[0]), second = clean(halves[1])
            // The English half first, as the guide requires; pick by which half is which, not by order
            // alone, so a body written the other way round still reads correctly.
            let firstIsEnglish = !containsHan(first.joined())
            let english = firstIsEnglish ? first : second
            let chinese = firstIsEnglish ? second : first
            if !english.isEmpty && !chinese.isEmpty { return lang == .zh ? chinese : english }
        }

        // Shape 2: `**中文**` / `**English**` markers.
        var zh: [String] = [], en: [String] = []
        var marked = 0
        for raw in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("---") { continue }
            if s.hasPrefix("#") {
                while s.hasPrefix("#") { s.removeFirst() }
                s = s.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { zh.append(s); en.append(s) }
                continue
            }
            if let r = s.range(of: "**中文**") {
                marked += 1
                zh.append(s[r.upperBound...].replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces))
            } else if let r = s.range(of: "**English**") {
                marked += 1
                en.append(s[r.upperBound...].replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces))
            } else {
                s = s.replacingOccurrences(of: "**", with: "")
                if containsHan(s) { zh.append(s) } else { en.append(s) }
            }
        }
        if marked > 0, !zh.isEmpty, !en.isEmpty { return lang == .zh ? zh : en }

        // Neither shape: show it as it is.
        return clean(notes)
    }

    /// One half of a body as display lines: heading marks and bold marks stripped, blanks dropped.
    private static func clean(_ half: String) -> [String] {
        half.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("---") { return nil }
            while s.hasPrefix("#") { s.removeFirst() }
            s = s.replacingOccurrences(of: "**中文**", with: "")
                 .replacingOccurrences(of: "**English**", with: "")
                 .replacingOccurrences(of: "**", with: "")
                 .trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
    }

    private static func containsHan(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) }
    }
}
