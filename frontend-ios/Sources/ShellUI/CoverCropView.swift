import CoreGraphics
import SwiftUI
#if canImport(PhotosUI)
import PhotosUI
#endif

/// Active state for an interactive 16:9 cover crop session.
public struct CoverCropSession: Identifiable {
    public let id: UUID
    public let gameID: String
    public let gameTitle: String
    public let image: CGImage

    public init(id: UUID = UUID(), gameID: String, gameTitle: String, image: CGImage) {
        self.id = id
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.image = image
    }
}

/// Interactive full-screen 16:9 cover cropper supporting drag, pinch zoom, double-tap reset and re-picking.
public struct CoverCropView: View {
    public let gameTitle: String
    public let initialImage: CGImage
    public let allowsPhotoRepick: Bool
    public let onConfirm: (Data) -> Void
    public let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellIgnoresPress) private var ignoresPress

    @State private var image: CGImage
    @State private var viewport = CoverCropViewport()
    @State private var lastCropSize: CGSize = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var pinchScale: CGFloat = 1
    @State private var exporting = false
    @State private var loadError = false
    @State private var decodeGeneration: UInt64 = 0
    #if canImport(PhotosUI)
    @State private var repickPresented = false
    @State private var repickItem: PhotosPickerItem?
    #endif

    private let frameCornerRadius: CGFloat = 14

    public init(
        gameTitle: String,
        image: CGImage,
        allowsPhotoRepick: Bool = true,
        onConfirm: @escaping (Data) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.gameTitle = gameTitle
        self.initialImage = image
        self.allowsPhotoRepick = allowsPhotoRepick
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _image = State(initialValue: image)
    }

    private var imageSize: CGSize {
        CGSize(width: max(1, image.width), height: max(1, image.height))
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                cropCanvas
                bottomBar
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        #if canImport(PhotosUI)
        .photosPicker(isPresented: $repickPresented, selection: $repickItem, matching: .images, photoLibrary: .shared())
        .onChange(of: repickItem) { _, item in
            guard let item else { return }
            repickItem = nil
            loadReplacement(item)
        }
        #endif
        .accessibilityIdentifier("coverCrop.view")
    }

    private var topBar: some View {
        VStack(spacing: 4) {
            Text(ShellStrings.text("Adjust Cover"))
                .shellText(17, .semibold, relativeTo: .headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("coverCrop.title")
            if !gameTitle.isEmpty {
                Text(gameTitle)
                    .shellText(13, .medium, relativeTo: .footnote)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Text(loadError
                 ? ShellStrings.text("This image could not be opened. Choose a different photo.")
                 : ShellStrings.text("Drag and pinch to fit 16:9. Double-tap to reset."))
                .shellText(12.5, .regular, relativeTo: .footnote)
                .foregroundStyle(loadError ? ShellPalette.attention : .white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var cropCanvas: some View {
        GeometryReader { geometry in
            let canvasSize = geometry.size
            let cropSize = Self.cropFrameSize(in: canvasSize)
            let active = liveViewport(for: cropSize)
            let displayW = imageSize.width * active.scale
            let displayH = imageSize.height * active.scale

            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displayW, height: displayH)
                    .offset(active.offset)
                    .allowsHitTesting(false)

                CropMaskOverlay(
                    cropSize: cropSize,
                    cornerRadius: frameCornerRadius
                )
                .allowsHitTesting(false)
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !exporting else { return }
                        dragTranslation = value.translation
                    }
                    .onEnded { value in
                        guard !exporting else { return }
                        let committed = viewport.transformed(
                            magnification: pinchScale,
                            translation: value.translation,
                            imageSize: imageSize,
                            viewportSize: cropSize
                        )
                        dragTranslation = .zero
                        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.88)) {
                            viewport = committed
                        }
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        guard !exporting else { return }
                        pinchScale = value.magnification
                    }
                    .onEnded { value in
                        guard !exporting else { return }
                        let committed = viewport.transformed(
                            magnification: value.magnification,
                            translation: dragTranslation,
                            imageSize: imageSize,
                            viewportSize: cropSize
                        )
                        pinchScale = 1
                        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.88)) {
                            viewport = committed
                        }
                    }
            )
            .onTapGesture(count: 2) {
                guard !exporting else { return }
                dragTranslation = .zero
                pinchScale = 1
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
                    viewport = CoverCropViewport.initial(imageSize: imageSize, viewportSize: cropSize)
                }
            }
            .onAppear {
                syncCropSize(cropSize)
            }
            .onChange(of: cropSize) { _, newSize in
                syncCropSize(newSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                if !ignoresPress() { onCancel() }
            } label: {
                Text(ShellStrings.text("Cancel"))
                    .shellType(ShellType.button)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(.white.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .disabled(exporting)
            .accessibilityIdentifier("coverCrop.cancel")
            .shellTarget("crp.cancel", enabled: !exporting, radius: ShellFocusTarget.capsule) { onCancel() }

            Spacer(minLength: 8)

            #if canImport(PhotosUI)
            if allowsPhotoRepick {
                Button {
                    if !ignoresPress() { repickPresented = true }
                } label: {
                    Label(ShellStrings.text("Choose Photo…"), systemImage: "photo.on.rectangle")
                        .shellType(ShellType.button)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .disabled(exporting)
                .accessibilityIdentifier("coverCrop.repick")
                .shellTarget("crp.repick", enabled: !exporting, radius: ShellFocusTarget.capsule) { repickPresented = true }

                Spacer(minLength: 8)
            }
            #endif

            Button {
                if !ignoresPress() { confirmCrop() }
            } label: {
                HStack(spacing: 8) {
                    if exporting {
                        ProgressView()
                            .tint(.black)
                            .scaleEffect(0.85)
                    }
                    Text(ShellStrings.text("Done"))
                        .shellType(ShellType.button)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 22)
                .frame(minHeight: 44)
                .background(ShellPalette.cream, in: Capsule())
                .opacity(exporting ? 0.7 : 1)
            }
            .buttonStyle(.plain)
            .disabled(exporting)
            .accessibilityIdentifier("coverCrop.done")
            .shellTarget("crp.done", enabled: !exporting, radius: ShellFocusTarget.capsule) { confirmCrop() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    static func cropFrameSize(in canvasSize: CGSize) -> CGSize {
        let maxW = max(120, canvasSize.width - 40)
        let maxH = max(68, canvasSize.height - 32)
        let width = min(maxW, maxH * CoverCropViewport.aspectRatio)
        return CGSize(width: width, height: width / CoverCropViewport.aspectRatio)
    }

    private func liveViewport(for cropSize: CGSize) -> CoverCropViewport {
        viewport.transformed(
            magnification: pinchScale,
            translation: dragTranslation,
            imageSize: imageSize,
            viewportSize: cropSize
        )
    }

    private func syncCropSize(_ newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0 else { return }
        if lastCropSize == .zero {
            viewport = CoverCropViewport.initial(imageSize: imageSize, viewportSize: newSize)
        } else if lastCropSize != newSize {
            viewport = viewport.adapted(from: lastCropSize, to: newSize, imageSize: imageSize)
        }
        lastCropSize = newSize
    }

    private func confirmCrop() {
        guard !exporting else { return }
        let cropSize = lastCropSize.width > 0 ? lastCropSize : CGSize(width: 320, height: 180)
        let finalViewport = liveViewport(for: cropSize)
        let sourceImage = image
        exporting = true
        Task {
            let jpeg = await Task.detached(priority: .userInitiated) {
                CoverImageProcessor.renderCroppedJPEG(
                    from: sourceImage,
                    viewport: finalViewport,
                    viewportSize: cropSize
                )
            }.value
            exporting = false
            if let jpeg {
                onConfirm(jpeg)
            } else {
                loadError = true
            }
        }
    }

    #if canImport(PhotosUI)
    private func loadReplacement(_ item: PhotosPickerItem) {
        decodeGeneration &+= 1
        let generation = decodeGeneration
        loadError = false
        Task {
            let rawData = try? await item.loadTransferable(type: Data.self)
            let decoded: CGImage?
            if let rawData {
                decoded = await Task.detached(priority: .userInitiated) {
                    CoverImageProcessor.decodeNormalizedImage(from: rawData)
                }.value
            } else {
                decoded = nil
            }
            guard decodeGeneration == generation else { return }
            guard let decoded else {
                loadError = true
                return
            }
            image = decoded
            dragTranslation = .zero
            pinchScale = 1
            let size = lastCropSize.width > 0 ? lastCropSize : CGSize(width: 320, height: 180)
            viewport = CoverCropViewport.initial(
                imageSize: CGSize(width: decoded.width, height: decoded.height),
                viewportSize: size
            )
        }
    }
    #endif
}

/// Even-odd dimmed mask with a crisp 16:9 rounded cutout, white border, and subtle rule-of-thirds grid.
private struct CropMaskOverlay: View {
    let cropSize: CGSize
    let cornerRadius: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let frame = CGRect(
                x: (bounds.width - cropSize.width) * 0.5,
                y: (bounds.height - cropSize.height) * 0.5,
                width: cropSize.width,
                height: cropSize.height
            )
            ZStack {
                Path { path in
                    path.addRect(bounds)
                    path.addRoundedRect(
                        in: frame,
                        cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
                    )
                }
                .fill(Color.black.opacity(0.64), style: FillStyle(eoFill: true))

                // Rule-of-thirds guide lines inside the 16:9 frame.
                Path { path in
                    for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
                        let x = frame.width * fraction
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: frame.height))

                        let y = frame.height * fraction
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: frame.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.28), lineWidth: 0.75)
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .position(x: frame.midX, y: frame.midY)

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.88), lineWidth: 1.5)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
    }
}

private struct ShellAskChangeCoverKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((GameTile) -> Void)? = nil
}

extension EnvironmentValues {
    var shellAskChangeCover: ((GameTile) -> Void)? {
        get { self[ShellAskChangeCoverKey.self] }
        set { self[ShellAskChangeCoverKey.self] = newValue }
    }
}
