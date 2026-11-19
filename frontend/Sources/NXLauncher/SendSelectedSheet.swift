import AppKit
import ImageIO
import SwiftUI
import NXCore
import NXModel

/// Checklist sheet for sending or copying game data of one or more packed library games (#1080).
package struct SendSelectedSheet: View {
    package enum Mode: String, Identifiable {
        case device
        case drive
        package var id: String { rawValue }
    }

    let mode: Mode
    @ObservedObject var build: BuildStore
    let close: () -> Void
    @Environment(\.selectionArtworkDirectory) private var artworkDirectory
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject private var pad: PadFocus
    @State private var parentScope = "main"
    @State private var parentFocus: String?
    private static var scope: String { "sendSelected" }
    @State private var icons: [String: NSImage] = [:]
    @State private var checked: Set<String> = []
    @State private var didSeedSelection = false

    package init(mode: Mode, build: BuildStore, close: @escaping () -> Void) {
        self.mode = mode
        self.build = build
        self.close = close
    }

    private static let iconPixels = 192
    private var maxSheetHeight: CGFloat { min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 80) }
    private var sources: [TransferSource] { build.sharedAppDataSources() }
    private var iconLoadKey: String { artworkDirectory.path + "\n" + sources.map { $0.titleID.uppercased() }.joined(separator: ",") }

    private var selectedSources: [TransferSource] {
        sources.filter { checked.contains($0.titleID.uppercased()) }
    }

    private var allChecked: Bool {
        !sources.isEmpty && selectedSources.count == sources.count
    }

    private var batchDriveState: DriveState? {
        guard mode == .drive, !selectedSources.isEmpty else { return nil }
        return build.driveBatchState(for: selectedSources)
    }

    private var canConfirm: Bool {
        guard !selectedSources.isEmpty else { return false }
        switch mode {
        case .device:
            return build.canSendAllGameData
        case .drive:
            guard !build.running, let state = batchDriveState else { return false }
            return state.problem == nil && state.volume != nil
        }
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t("shell.selectGamesTitle"))
                        .font(.manrope(26, .heavy))
                        .tracking(-0.5)
                    Text(loc.t(mode == .device ? "shell.selectGamesDeviceNote" : "shell.selectGamesDriveNote"))
                        .font(.manrope(13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if !sources.isEmpty {
                    Button(loc.t(allChecked ? "shell.clearSelection" : "shell.selectAll"), action: toggleAll)
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .fixedSize()
                    .padTarget("sendSelected.all", scope: Self.scope, activate: toggleAll)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .padding(.bottom, 18)

            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(sources, id: \.titleID) { source in
                        let key = source.titleID.uppercased()
                        let isChecked = checked.contains(key)
                        let bytes = build.transferSourceBytes(source)
                        Button { toggle(key) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 17))
                                    .foregroundStyle(isChecked ? LauncherPalette.ready : .secondary)
                                Group {
                                    if let icon = icons[key] { Image(nsImage: icon).resizable().scaledToFill() }
                                    else { Image(systemName: "gamecontroller.fill").frame(maxWidth: .infinity, maxHeight: .infinity).background(LauncherPalette.surface) }
                                }.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.name)
                                        .font(.manrope(14, .medium))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)

                                }
                                Spacer(minLength: 8)
                                if bytes > 0 {
                                    Text(ShellInstall.sizeText(bytes))
                                        .font(.manrope(12.5, .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            .background(isChecked ? LauncherPalette.ink(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isChecked ? .isSelected : [])
                        .accessibilityValue(source.titleID.uppercased())
                        .padTarget("sendSelected.game." + key, scope: Self.scope, radius: 8, activate: { toggle(key) })
                        .padding(.horizontal, 20)
                    }
                }
            }

            .onChange(of: pad.focused) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }

            if mode == .drive, let state = batchDriveState {
                driveBanner(state)
                    .padding(.horizontal, 30)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            }

            Divider().opacity(0.3)

            HStack(spacing: 12) {
                Spacer()
                Button(loc.t("saves.cancel"), action: close)
                    .buttonStyle(LauncherSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .padTarget("sendSelected.cancel", scope: Self.scope, activate: close)
                Button { confirm() } label: {
                    Text(loc.t(mode == .device ? "shell.sendSelectedConfirm" : "shell.copySelectedConfirm"))
                        .font(.manrope(14, .semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(LauncherActionButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
                .opacity(canConfirm ? 1 : 0.4)
                .padTarget("sendSelected.confirm", scope: Self.scope, focusColor: LauncherPalette.onCream, enabled: canConfirm, activate: confirm)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
        }
        .background(PadKeyboardInput(focus: pad, scope: Self.scope, back: close))
        .environment(\.padRingStyle, .hug)
        .padScope(Self.scope, pad)
        .frame(width: 680)
        .frame(minHeight: min(420, maxSheetHeight), maxHeight: maxSheetHeight)
        .background(LauncherPalette.background)
        .launcherAppearance()
        .task(id: iconLoadKey) {
            let keys = sources.map { $0.titleID.uppercased() }
            let directory = artworkDirectory
            let loaded = await Task.detached(priority: .userInitiated) {
                var result: [String: NSImage] = [:]
                for key in keys {
                    if let image = Self.loadDownsampledIcon(for: key, in: directory, maxPixel: Self.iconPixels) {
                        result[key] = image
                    }
                }
                return result
            }.value
            guard !Task.isCancelled else { return }
            icons = loaded
        }
        .onAppear {
            parentScope = pad.scope; parentFocus = pad.focused
            pad.scope = Self.scope
            pad.focused = sources.first.map { "sendSelected.game." + $0.titleID.uppercased() } ?? "sendSelected.cancel"
            if !didSeedSelection {
                didSeedSelection = true
                checked = Set(sources.map { $0.titleID.uppercased() })
            }
        }
        .onDisappear {
            if pad.scope == Self.scope { pad.scope = parentScope; pad.focused = parentFocus }
        }
    }

    private func toggleAll() {
        if allChecked { checked.removeAll() }
        else { checked = Set(sources.map { $0.titleID.uppercased() }) }
    }

    @ViewBuilder private func driveBanner(_ state: DriveState) -> some View {
        switch state.problem {
        case .fat32:
            bannerRow(symbol: "exclamationmark.triangle.fill", color: .red, text: loc.t("shell.driveFat32"))
        case .readOnly:
            bannerRow(symbol: "exclamationmark.triangle.fill", color: .red, text: loc.t("shell.driveReadOnly"))
        case .noSpace(let needed, let free):
            bannerRow(
                symbol: "exclamationmark.triangle.fill",
                color: .red,
                text: String(format: loc.t("shell.driveNoSpace"), ShellInstall.sizeText(needed), ShellInstall.sizeText(free))
            )
        case nil:
            if let volume = state.volume {
                let gameDataRow = L10n.string("ios.ui.gameData", loc.lang)
                bannerRow(
                    symbol: "info.circle",
                    color: .secondary,
                    text: String(
                        format: loc.t("shell.driveNote"),
                        ShellInstall.sizeText(state.needed),
                        ShellInstall.sizeText(volume.freeBytes),
                        DriveCopy.fileSystemName(volume.fileSystem),
                        gameDataRow
                    )
                )
            }
        }
    }

    private func bannerRow(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 13)
            Text(text)
                .font(.manrope(12.5))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func toggle(_ key: String) {
        if checked.contains(key) {
            checked.remove(key)
        } else {
            checked.insert(key)
        }
    }

    private func confirm() {
        guard canConfirm else { return }
        switch mode {
        case .device:
            build.sendSelectedGameData(titleIDs: checked)
        case .drive:
            build.copySelectedToDrive(titleIDs: checked)
        }
        close()
    }

    /// Downsampled off-main-thread icon loader: cached `icon.jpg` → offline `nacp-icon.jpg` → center-cropped banner.
    private static func loadDownsampledIcon(for titleID: String, in directory: URL, maxPixel: Int) -> NSImage? {
        if let icon = BannerCache.cachedIcon(titleID, in: directory),
           let image = decodeThumbnail(at: icon, maxPixel: maxPixel, squareCrop: false) {
            return image
        }
        if let banner = BannerCache.cached(titleID, in: directory),
           let image = decodeThumbnail(at: banner, maxPixel: maxPixel, squareCrop: true) {
            return image
        }
        return nil
    }

    private static func decodeThumbnail(at url: URL, maxPixel: Int, squareCrop: Bool) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, w > 0,
              let h = props[kCGImagePropertyPixelHeight] as? Int, h > 0 else { return nil }
        let longSide = max(w, h)
        let shortSide = max(1, min(w, h))
        let requestedMax: Int
        if squareCrop && w != h {
            let scaled = Int(ceil(Double(maxPixel) * Double(longSide) / Double(shortSide)))
            requestedMax = min(longSide, min(maxPixel * 4, max(maxPixel, scaled)))
        } else {
            requestedMax = min(maxPixel, longSide)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: requestedMax,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let finalCG: CGImage
        if squareCrop && thumb.width != thumb.height {
            let side = min(thumb.width, thumb.height)
            let rect = CGRect(x: (thumb.width - side) / 2, y: (thumb.height - side) / 2, width: side, height: side)
            finalCG = thumb.cropping(to: rect) ?? thumb
        } else {
            finalCG = thumb
        }
        let image = NSImage(size: NSSize(width: finalCG.width, height: finalCG.height))
        image.addRepresentation(NSBitmapImageRep(cgImage: finalCG))
        return image
    }
}

private struct SelectionArtworkDirectoryKey: EnvironmentKey { static let defaultValue = BannerCache.directory }
extension EnvironmentValues {
    package var selectionArtworkDirectory: URL {
        get { self[SelectionArtworkDirectoryKey.self] }
        set { self[SelectionArtworkDirectoryKey.self] = newValue }
    }
}
