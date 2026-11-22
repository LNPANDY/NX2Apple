import SwiftUI

/// Localized step instructions shared between the in-app guide and the floating PiP step card.
public enum HomeScreenGuideSteps {
    /// Complete 6-step guide shown inside `AddToHomeScreenView`.
    public static func allSteps() -> [String] {
        [
            ShellStrings.text("Tap below to save the cover icon to Photos and copy the game title."),
            ShellStrings.text("In Shortcuts, search for NX2Apple and select the Launch Game action."),
            ShellStrings.text("In the Launch Game card, tap Choose next to Game and pick this game."),
            ShellStrings.text("Tap Launch Game at the top, choose Rename, and paste the copied game title."),
            ShellStrings.text("Tap the Share button at the bottom and choose Add to Home Screen."),
            ShellStrings.text("Tap the icon, pick Choose Photo, select the saved cover, then tap Add."),
        ]
    }

    /// The 5 steps performed inside Apple Shortcuts after tapping Save Icon & Open Shortcuts.
    public static func shortcutsSteps() -> [String] {
        Array(allSteps().dropFirst())
    }

    /// Footer hint shown inside the floating PiP step card.
    public static func pipControlsHint() -> String {
        ShellStrings.text("Tap back or forward to switch steps")
    }
}

/// Guides the player through adding a standalone game icon to the iOS Home Screen via Shortcuts and `AppIntents`.
public struct AddToHomeScreenView: View {
    public let game: GameTile
    public let supportsFloatingGuide: Bool
    public let prepareFloatingGuide: (() -> Void)?
    public let cancelPreparedFloatingGuide: (() -> Void)?
    public let saveAndOpen: @MainActor (Bool) async -> Bool
    public let copyURL: () -> Void
    public let close: () -> Void

    @Environment(\.shellNativeBars) private var nativeBars
    @State private var floatingGuideEnabled = true
    @State private var didTriggerSaveAndOpen = false
    @State private var saving = false
    @State private var savedFeedback = false
    @State private var saveFailed = false
    @State private var copiedFeedback = false
    @State private var resetSavedTask: Task<Void, Never>?
    @State private var resetCopiedTask: Task<Void, Never>?

    public init(
        game: GameTile,
        supportsFloatingGuide: Bool = false,
        prepareFloatingGuide: (() -> Void)? = nil,
        cancelPreparedFloatingGuide: (() -> Void)? = nil,
        saveAndOpen: @escaping @MainActor (Bool) async -> Bool,
        copyURL: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.game = game
        self.supportsFloatingGuide = supportsFloatingGuide
        self.prepareFloatingGuide = prepareFloatingGuide
        self.cancelPreparedFloatingGuide = cancelPreparedFloatingGuide
        self.saveAndOpen = saveAndOpen
        self.copyURL = copyURL
        self.close = close
    }

    public init(
        game: GameTile,
        saveAndOpen: @escaping @MainActor () async -> Bool,
        copyURL: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.init(
            game: game,
            supportsFloatingGuide: false,
            prepareFloatingGuide: nil,
            cancelPreparedFloatingGuide: nil,
            saveAndOpen: { _ in await saveAndOpen() },
            copyURL: copyURL,
            close: close
        )
    }

    public var body: some View {
        let steps = HomeScreenGuideSteps.allSteps()
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                HomeScreenIconPreview(game: game)
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ShellStrings.text("Add to Home Screen"))
                        .shellType(ShellType.pageTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("homeScreen.title")
                    Text(game.title)
                        .shellText(14, .medium)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                    stepRow(index + 1, text)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))

            if supportsFloatingGuide {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $floatingGuideEnabled) {
                        Text(ShellStrings.text("Floating Step Guide (PiP)"))
                            .shellText(14.5, .semibold)
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .toggleStyle(NativeCreamToggleStyle())
                    .accessibilityIdentifier("homeScreen.pipToggle")

                    Text(ShellStrings.text("Keep the steps floating over Shortcuts. Use back or forward in the floating window to switch steps."))
                        .shellText(12.5)
                        .foregroundStyle(.white.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
            }

            if saveFailed {
                Text(ShellStrings.text("Allow photo access in Settings to save the icon, or copy the launch URL below."))
                    .shellText(13)
                    .foregroundStyle(ShellPalette.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("homeScreen.photoDenied")
            }

            VStack(spacing: 10) {
                Button(action: triggerSaveAndOpen) {
                    Text(savedFeedback
                         ? "✓ " + ShellStrings.text("Icon Saved & Title Copied")
                         : ShellStrings.text("Save Icon & Open Shortcuts"))
                }
                .buttonStyle(PrimaryPillStyle(expands: true))
                .disabled(saving)
                .accessibilityIdentifier("homeScreen.save")
                .shellTarget("hsc.save", enabled: !saving, radius: ShellFocusTarget.capsule, action: triggerSaveAndOpen)

                Button(action: triggerCopyURL) {
                    Text(copiedFeedback
                         ? "✓ " + ShellStrings.text("URL Copied")
                         : ShellStrings.text("Copy Launch URL"))
                }
                .buttonStyle(SecondaryPillStyle())
                .accessibilityIdentifier("homeScreen.copy")
                .shellTarget("hsc.copy", radius: ShellFocusTarget.capsule, action: triggerCopyURL)

                if !nativeBars {
                    Button(action: close) {
                        Text(ShellStrings.text("Close"))
                    }
                    .buttonStyle(SecondaryPillStyle())
                    .accessibilityIdentifier("homeScreen.close")
                    .shellTarget("hsc.close", radius: ShellFocusTarget.capsule, action: close)
                }
            }
            .padding(.top, 2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .onAppear {
            if supportsFloatingGuide && floatingGuideEnabled {
                prepareFloatingGuide?()
            }
        }
        .onChange(of: floatingGuideEnabled) { _, enabled in
            guard supportsFloatingGuide else { return }
            if enabled {
                prepareFloatingGuide?()
            } else {
                cancelPreparedFloatingGuide?()
            }
        }
        .onDisappear {
            resetSavedTask?.cancel()
            resetCopiedTask?.cancel()
            if !didTriggerSaveAndOpen {
                cancelPreparedFloatingGuide?()
            }
        }
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .shellText(12, .bold)
                .foregroundStyle(.black.opacity(0.88))
                .monospacedDigit()
                .frame(width: 20, height: 20)
                .background(ShellPalette.cream, in: Circle())
            Text(text)
                .shellText(14)
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("homeScreen.step.\(number)")
    }

    private func triggerSaveAndOpen() {
        guard !saving else { return }
        saving = true
        saveFailed = false
        let useFloatingGuide = supportsFloatingGuide && floatingGuideEnabled
        if useFloatingGuide {
            didTriggerSaveAndOpen = true
        }
        Task { @MainActor in
            let ok = await saveAndOpen(useFloatingGuide)
            saving = false
            guard ok else {
                didTriggerSaveAndOpen = false
                saveFailed = true
                return
            }
            savedFeedback = true
            resetSavedTask?.cancel()
            resetSavedTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { savedFeedback = false }
            }
        }
    }

    private func triggerCopyURL() {
        copyURL()
        copiedFeedback = true
        resetCopiedTask?.cancel()
        resetCopiedTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { copiedFeedback = false }
        }
    }
}

/// Square app-icon preview with continuous iOS squircle corners.
private struct HomeScreenIconPreview: View {
    let game: GameTile

    var body: some View {
        Color.clear
            .overlay {
                if let icon = game.icon {
                    Image(decorative: icon.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else if let banner = game.banner {
                    Image(decorative: banner.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    PlaceholderArt(title: game.title, seed: game.id, lettering: true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
    }
}

/// Matching translucent capsule for secondary actions below `PrimaryPillStyle`.
private struct SecondaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .shellType(ShellType.button)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(.white.opacity(0.92))
            .background(.white.opacity(configuration.isPressed ? 0.15 : 0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Capsule())
    }
}

private struct ShellAskHomeScreenKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((GameTile) -> Void)? = nil
}

extension EnvironmentValues {
    var shellAskHomeScreen: ((GameTile) -> Void)? {
        get { self[ShellAskHomeScreenKey.self] }
        set { self[ShellAskHomeScreenKey.self] = newValue }
    }
}
