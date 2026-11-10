import NXCore
import NXLauncher
import SwiftUI
import UniformTypeIdentifiers

/// The artwork editor's panel (design C): a column beside the library, which stays visible behind it as the live preview of the
/// editor's draft. Hero and Thumbnail tabs, a grid of the images the game has (the eShop banner and screenshots, the player's own
/// files), Reset, Cancel and Save. The state is `ArtworkEditor`, so this is only the view.
struct ArtworkPanel: View {
    static let width: CGFloat = 420
    private static let slots: [ArtworkSlot] = [.hero, .thumbnail]

    @ObservedObject var editor: ArtworkEditor
    let labels: (String) -> String
    var dropped = false   // the drop highlight drawn from the start (visual QA)
    let save: () -> Void
    let cancel: () -> Void
    @EnvironmentObject private var focus: PadFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var gridFocused: Bool
    @FocusState private var framingFocused: Bool

    private func t(_ key: String) -> String { labels(key) }
    private var slotName: String { editor.slot.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("artwork.title")).font(.manrope(26, .heavy)).tracking(-0.6).accessibilityAddTraits(.isHeader)
                Text(editor.gameName).font(.manrope(14)).foregroundStyle(LauncherPalette.secondaryText).lineLimit(1)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            tabs.padding(.horizontal, 24).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    grid
                    if editor.isLoading { Text(t("artwork.loading")).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText) }
                    if editor.loadState == .offline { offline }
                    if let notice = editor.notice { noticeRow(notice) }
                    if editor.needsFraming { framing }
                }
                .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 16)
                .task(id: editor.selectedFile) { await editor.measureSelected() }
            }
            Divider().opacity(0.3)
            footer
        }
        .padScope("artwork", focus)
        .frame(width: Self.width).frame(maxHeight: .infinity)
        .background(LauncherPalette.background)
        .font(.manrope(13))
        .modifier(GameFilesDrop(enabled: true, label: t("artwork.dropHint." + slotName), targeted: dropped) { paths in
            if let path = paths.first { Task { await editor.importFile(URL(fileURLWithPath: path)) } }
        })
        .onAppear { editor.start(); gridFocused = true }
        .onExitCommand(perform: cancel)
    }


    /// The top bar's tab style: the chosen one a pale pill, bold. The bold text sizes both, so a tab never changes width.
    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(Self.slots, id: \.self) { slot in
                let on = editor.slot == slot
                let title = t("artwork.tab." + slot.rawValue)
                Button { editor.slot = slot } label: {
                    ZStack {
                        Text(title).font(.manrope(14, .bold)).hidden()
                        Text(title).font(.manrope(14, on ? .bold : .medium))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(on ? LauncherPalette.ink(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .padTarget("artwork.tab." + slot.rawValue, scope: "artwork") { editor.slot = slot }
            }
        }
    }


    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: ArtworkEditor.columns), spacing: 10) {
            ForEach(editor.tiles) { tile in tileButton(tile) }
            if editor.isLoading { ForEach(0..<ArtworkStore.maxScreenshots, id: \.self) { _ in SkeletonTile(animated: !reduceMotion, aspect: editor.tileAspect) } }
            chooseFile
        }
        .focusable()
        .focused($gridFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left: editor.move(.left)
            case .right: editor.move(.right)
            case .up: editor.move(.up)
            case .down: editor.move(.down)
            @unknown default: break
            }
        }
        // The grid is one stop for the keyboard: Return and Space choose the tile the arrows are on, only while it has the focus
        // (a space typed in the search field stays a space)
        .background {
            Group {
                Button("") { editor.selectCursor() }.keyboardShortcut(.return, modifiers: [])
                Button("") { editor.selectCursor() }.keyboardShortcut(.space, modifiers: [])
            }
            .disabled(!gridFocused)
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(editor.gridLabel)
    }

    private func tileButton(_ tile: ArtworkEditor.Tile) -> some View {
        Button { editor.select(tile) } label: {
            Color.clear.aspectRatio(editor.tileAspect, contentMode: .fit)
                .overlay {
                    if let file = tile.file, let image = ArtworkImages.shared.image(at: file, maxPixel: 480) {
                        ArtworkFill(image: image)
                    } else {
                        ZStack {
                            LauncherPalette.surface
                            Image(systemName: tile.isFailed ? "photo.badge.exclamationmark" : "photo").font(.system(size: 15, weight: .light)).foregroundStyle(LauncherPalette.secondaryText)
                        }
                    }
                }
                .overlay(alignment: .topLeading) { if tile.isHero { badge(t("artwork.heroBadge")) } }
                .overlay(alignment: .bottomLeading) { if tile.isLowResolution { badge(t("artwork.lowResBadge")) } }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tile.isSelected ? LauncherPalette.accent : LauncherPalette.ink(0.08), lineWidth: tile.isSelected ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(editor.label(for: tile))
        .accessibilityAddTraits(tile.isSelected ? .isSelected : [])
        .padTarget("artwork.tile." + tile.id, scope: "artwork", radius: 5) { editor.select(tile) }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.manrope(11, .semibold)).foregroundStyle(.white.opacity(0.92)).lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.black.opacity(0.72), in: Capsule())
            .padding(4)
    }

    /// The last cell. It opens the file picker, which a controller cannot use: it is no pad target.
    private var chooseFile: some View {
        Button(action: pickFile) {
            Color.clear.aspectRatio(editor.tileAspect, contentMode: .fit)
                .overlay {
                    VStack(spacing: 3) {
                        Image(systemName: "folder").font(.system(size: 14, weight: .light))
                        Text(t("artwork.chooseFile")).font(.manrope(10.5, .medium)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(LauncherPalette.secondaryText).padding(.horizontal, 4)
                }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(LauncherPalette.ink(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("artwork.chooseFile"))
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.message = t("library.artworkHint")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await editor.importFile(url) }
    }


    /// Where the point to keep is chosen, for an image the slot crops by 5 % or more.
    private var framing: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t("artwork.framing")).font(.manrope(13, .semibold))
                Spacer(minLength: 8)
                if !editor.isCentered {
                    Button(t("artwork.framing.center")) { editor.recenter() }.buttonStyle(LauncherSecondaryButtonStyle())
                        .controlSize(.small)
                        .padTarget("artwork.framing.center", scope: "artwork", radius: 9) { editor.recenter() }
                }
            }
            .frame(minHeight: 32)
            framingPreview
        }
    }

    /// The chosen image fitted on a dim surface, the parts the slot cuts shaded, the band outlined and a ring at its centre. The
    /// band sits where ArtworkFraming crops the image for the focus, so it follows the point along the one axis that is cut.
    private var framingPreview: some View {
        let focus = editor.focus
        let image = editor.framingImageSize ?? CGSize(width: 16, height: 9)
        let band = editor.framingBand
        let file = editor.selectedFile
        return GeometryReader { area in
            let fitted = Self.fit(image, in: area.size)
            let slot = Self.band(band, in: fitted, focus: focus)
            ZStack(alignment: .topLeading) {
                if let file, let picture = ArtworkImages.shared.image(at: file, maxPixel: 800) {
                    Image(nsImage: picture).resizable().frame(width: fitted.width, height: fitted.height)
                        .offset(x: fitted.minX, y: fitted.minY)
                }
                Path { path in path.addRect(fitted); path.addRect(slot) }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Rectangle().strokeBorder(LauncherPalette.accent, lineWidth: 2)
                    .frame(width: slot.width, height: slot.height).offset(x: slot.minX, y: slot.minY)
                Circle().fill(Color.black.opacity(0.35)).overlay(Circle().strokeBorder(LauncherPalette.cream, lineWidth: 2))
                    .frame(width: 18, height: 18).offset(x: slot.midX - 9, y: slot.midY - 9)
            }
            .frame(width: area.size.width, height: area.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                framingFocused = true
                editor.setFocus(Self.focus(at: drag.location, image: fitted, band: band, current: editor.focus))
            })
        }
        .aspectRatio(16 / 9, contentMode: .fit)   // the panel's full width, a 16:9 image filling it
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .focusable()
        .focused($framingFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left: editor.nudge(.left)
            case .right: editor.nudge(.right)
            case .up: editor.nudge(.up)
            case .down: editor.nudge(.down)
            @unknown default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("artwork.framing.point"))
        .accessibilityValue(Self.spoken(editor.cropsWidth ? focus.x : focus.y))   // the axis the point moves on
        .accessibilityHint(t("artwork.framing.hint"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: editor.adjustFocus(increment: true)
            case .decrement: editor.adjustFocus(increment: false)
            @unknown default: break
            }
        }
    }

    private static func fit(_ image: CGSize, in area: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: area) }
        let scale = min(area.width / image.width, area.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The band over the fitted image: as tall (or as wide) as the image, cut along the other axis, placed by the focus.
    private static func band(_ band: CGSize, in image: CGRect, focus: ArtworkFocus) -> CGRect {
        let imageAspect = image.width / image.height, bandAspect = band.width / band.height
        if imageAspect > bandAspect {
            let width = image.height * bandAspect
            return CGRect(x: image.minX + (image.width - width) * focus.x, y: image.minY, width: width, height: image.height)
        }
        let height = image.width / bandAspect
        return CGRect(x: image.minX, y: image.minY + (image.height - height) * focus.y, width: image.width, height: height)
    }

    /// The focus that puts the band's centre at `location`, on the axis that is cut. The other axis keeps its value.
    private static func focus(at location: CGPoint, image: CGRect, band: CGSize, current: ArtworkFocus) -> ArtworkFocus {
        let imageAspect = image.width / image.height, bandAspect = band.width / band.height
        var focus = current
        if imageAspect > bandAspect {
            let width = image.height * bandAspect
            focus.x = (location.x - image.minX - width / 2) / (image.width - width)
        } else {
            let height = image.width / bandAspect
            focus.y = (location.y - image.minY - height / 2) / (image.height - height)
        }
        return focus
    }

    private static func spoken(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }


    private var offline: some View {
        HStack(spacing: 12) {
            Label(t("artwork.offline"), systemImage: "wifi.slash").font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(t("artwork.retry")) { editor.retry() }.buttonStyle(LauncherSecondaryButtonStyle())
                .padTarget("artwork.retry", scope: "artwork") { editor.retry() }
        }
    }

    private func noticeRow(_ notice: ArtworkEditor.Notice) -> some View {
        let (text, symbol, color): (String, String, Color) = {
            switch notice {
            case .warning(let text): return (text, "exclamationmark.triangle.fill", LauncherPalette.building)
            case .error(let text): return (text, "exclamationmark.circle.fill", LauncherPalette.danger)
            }
        }()
        return Label(text, systemImage: symbol).font(.manrope(13)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    /// Reset, Cancel and Save on one row when the reset text fits (English, Chinese, Swedish), else Reset on a row of its own above
    /// (German, French, Italian), never cut short.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                if editor.canReset(editor.slot) { resetButton }
                Spacer(minLength: 8)
                cancelAndSave
            }
            VStack(alignment: .leading, spacing: 10) {
                if editor.canReset(editor.slot) { resetButton }
                HStack(spacing: 10) { Spacer(minLength: 0); cancelAndSave }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var resetButton: some View {
        Button { editor.reset(editor.slot) } label: { Label(t("artwork.reset." + slotName), systemImage: "arrow.uturn.backward").lineLimit(1).fixedSize() }
            .buttonStyle(LauncherSecondaryButtonStyle())
            .padTarget("artwork.reset", scope: "artwork", radius: 9) { editor.reset(editor.slot) }
    }

    @ViewBuilder private var cancelAndSave: some View {
        Button(t("artwork.cancel"), action: cancel).buttonStyle(LauncherSecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
            .padTarget("artwork.cancel", scope: "artwork", radius: 9, activate: cancel)
        Button(action: save) {
            Text(t("artwork.save")).font(.manrope(13.5, .bold))
                .padding(.horizontal, 22).padding(.vertical, 9)
        }
        .buttonStyle(LauncherActionButtonStyle()).opacity(editor.isDirty ? 1 : 0.4).keyboardShortcut("s", modifiers: .command).disabled(!editor.isDirty)
        .padTarget("artwork.save", scope: "artwork", radius: 20) { if editor.isDirty { save() } }
    }
}

/// A tile waiting for the list: a dim block of the grid's proportions that breathes, or stands still under Reduce Motion.
private struct SkeletonTile: View {
    let animated: Bool
    let aspect: CGFloat
    @State private var lit = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(LauncherPalette.ink(lit ? 0.10 : 0.05))
            .aspectRatio(aspect, contentMode: .fit)
            .accessibilityHidden(true)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
            }
    }
}
