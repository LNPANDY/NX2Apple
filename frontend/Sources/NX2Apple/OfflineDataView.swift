import SwiftUI
import AppKit
import NXCore

/// Optional sources are explicitly selected and inspected before packaging.
struct OfflineDataView: View {
    var t: (String) -> String
    @Binding var saveFolder: String
    @Binding var cacheFolder: String
    @State private var summary = ""
    @State private var error = ""
    @State private var inspection = UUID()
    @State private var inspecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("offline.title")).font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                Text(t("offline.note"))
                    .font(.caption).foregroundStyle(.secondary)
                sourceRow(t("offline.save"), path: $saveFolder, caches: false)
                sourceRow(t("offline.cache"), path: $cacheFolder, caches: true)
                if inspecting { ProgressView().controlSize(.small) }
                if !summary.isEmpty { Text(summary).font(.caption).foregroundStyle(.secondary) }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                Text(t("offline.privacy")).font(.caption).foregroundStyle(.secondary)
                Text(t("offline.warning"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func sourceRow(_ title: String, path: Binding<String>, caches: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(path.wrappedValue.isEmpty ? t("offline.none") : path.wrappedValue)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !path.wrappedValue.isEmpty { Button(t("offline.clear")) { inspection = UUID(); inspecting = false; path.wrappedValue = ""; summary = ""; error = "" } }
            Button(t("offline.choose")) { choose(path, caches: caches) }
        }
    }

    private func choose(_ path: Binding<String>, caches: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let request = UUID()
        inspection = request; inspecting = true; summary = ""; error = ""
        // Large cache trees must not block the UI. Only the latest selection may
        // publish its result, including when Clear invalidated a pending scan.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try OfflineDataInventory.inspect(url, caches: caches) }
            DispatchQueue.main.async {
                guard inspection == request else { return }
                inspecting = false
                switch result {
                case .success(let inventory):
                    path.wrappedValue = url.path
                    summary = String(format: t("offline.summary"), inventory.files, ByteCountFormatter.string(fromByteCount: inventory.bytes, countStyle: .file))
                    error = ""
                case .failure(let failure):
                    error = (failure as? OfflineDataInventory.ValidationError)?.message(t) ?? failure.localizedDescription
                }
            }
        }
    }
}
