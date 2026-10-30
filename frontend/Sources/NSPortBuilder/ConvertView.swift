import SwiftUI

/// Convert files with the bundled nsz: a compressed dump (.nsz/.xcz) to .nsp/.xci beside it, or a plain
/// package into a compressed one. One file at a time, the build's own interpreter, the log live below.
struct ConvertView: View {
    @ObservedObject var m: BuildModel
    @Environment(\.dismiss) private var dismiss
    @State private var paths: [String] = []
    @State private var log = ""
    @State private var running = false

    private var plan: [(path: String, kind: FileConvert.Kind, output: String)] { FileConvert.plan(for: paths) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.t("convert.title")).font(.manrope(26, .heavy)).tracking(-0.6)
                Text(m.t("convert.note")).font(.manrope(14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Button(m.t("convert.choose")) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
                        panel.allowedContentTypes = [.data]   // NSP/XCI/NSZ/XCZ have no registered type: pick anything, filter here
                        if panel.runModal() == .OK {
                            paths = panel.urls.map(\.path).filter { FileConvert.kind(for: $0) != nil }
                        }
                    }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    ForEach(plan, id: \.path) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.kind == .decompress ? "arrow.down.doc" : "arrow.up.doc")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((item.path as NSString).lastPathComponent).font(.manrope(13, .medium)).lineLimit(1)
                                Text("→ " + (item.output as NSString).lastPathComponent).font(.manrope(12)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if paths.isEmpty {
                        Text(m.t("convert.none")).font(.manrope(13)).foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                    if !log.isEmpty {
                        Text(log).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 16)
            }
            Divider().opacity(0.3)
            HStack(spacing: 14) {
                Text(running ? m.t("convert.running") : m.t("convert.ready")).font(.manrope(12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button(m.t("convert.run")) { run() }
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .disabled(plan.isEmpty || running)
                Button { dismiss() } label: {
                    Text(m.t("launch.done")).font(.manrope(13.5, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(LauncherPalette.cream, in: Capsule())
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .frame(width: 620, height: 640)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
    }

    /// One nsz run per file, in order, each writing beside its input. The same interpreter the build
    /// uses, so the bundled nsz runs and nothing new is installed.
    private func run() {
        let python = m.pythonPath.isEmpty ? BuildModel.findPython().path : m.pythonPath
        let jobs = plan
        guard !jobs.isEmpty else { return }
        running = true; log = ""
        DispatchQueue.global(qos: .userInitiated).async {
            for job in jobs {
                DispatchQueue.main.async { self.log += "$ " + FileConvert.command(python: python, kind: job.kind, path: job.path).joined(separator: " ") + "\n" }
                let r = BuildModel.runQuiet(FileConvert.command(python: python, kind: job.kind, path: job.path),
                                            env: BuildModel.gitEnv().merging(["HOME": NSHomeDirectory()]) { $1 })
                DispatchQueue.main.async {
                    self.log += r.ok ? "✓ " + FileConvert.output(for: job.path, kind: job.kind) + "\n"
                                     : "✗ " + r.out.suffix(400) + "\n"
                }
            }
            DispatchQueue.main.async { self.running = false }
        }
    }
}
