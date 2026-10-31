import SwiftUI

/// "A new version is out", with what it changes, shown when the app opens or Check for updates finds
/// one. The app already had the update machinery (checkAppUpdate / performAppUpdate); what it lacked
/// was a reason to press the button: the status line said a tag name and nothing else, and a user who
/// was working fine had no way to tell whether the new version mattered to them.
///
/// The notes come from the release body, which this project writes in both languages (see
/// docs/RELEASE-NOTES-GUIDE.md). The sheet does not try to translate them; it shows the lines that
/// match the interface language and falls back to the whole body when it cannot tell them apart.
/// ReleaseNotes turns them into blocks with links, and this file only styles those.
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
                VStack(alignment: .leading, spacing: 6) {
                    if let notes = update?.notes, !notes.isEmpty {
                        let blocks = ReleaseNotes.blocks(from: ReleaseNotes.markdown(notes, for: m.lang))
                        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                            blockView(block, first: index == 0)
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

    @ViewBuilder private func blockView(_ block: ReleaseNotes.Block, first: Bool) -> some View {
        switch block {
        case .heading(let text):
            Text(Self.styled(text, size: 12.5, weight: .bold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, first ? 0 : 14)
        case .bullet(let text):
            // A hanging indent: the bullet is its own column, so wrapped lines align with the text.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\u{2022}").font(.manrope(13)).foregroundStyle(.secondary).frame(width: 10, alignment: .center)
                Text(Self.styled(text, size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 2)
        case .paragraph(let text):
            Text(Self.styled(text, size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
        }
    }

    /// The launcher's look on a parsed line: Manrope, bold and italic runs, code in the monospaced face on a
    /// faint background, links in the accent colour. Links open in the default browser (SwiftUI's openURL).
    static func styled(_ text: AttributedString, size: CGFloat, weight: Font.Weight = .regular) -> AttributedString {
        var out = text
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = Font.manrope(size, intent.contains(.stronglyEmphasized) ? .bold : weight)
            if intent.contains(.emphasized) { font = font.italic() }
            if intent.contains(.code) {
                font = .mono(size - 1, intent.contains(.stronglyEmphasized) ? .bold : .regular)
                out[run.range].backgroundColor = Color.white.opacity(0.10)
            }
            out[run.range].font = font
            if run.link != nil {
                out[run.range].foregroundColor = LauncherPalette.cream
                out[run.range].underlineStyle = .single
            }
        }
        return out
    }
}
