import SwiftUI

private struct ShellAskSaveImportKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((SaveImportPrompt) -> Void)? = nil
}

private struct ShellShowSaveMessageKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var shellAskSaveImport: ((SaveImportPrompt) -> Void)? {
        get { self[ShellAskSaveImportKey.self] }
        set { self[ShellAskSaveImportKey.self] = newValue }
    }

    var shellShowSaveMessage: ((String) -> Void)? {
        get { self[ShellShowSaveMessageKey.self] }
        set { self[ShellShowSaveMessageKey.self] = newValue }
    }
}

/// Confirmation card before importing a picked save folder, `.zip` archive, or individual save file.
public struct SaveImportConfirmView: View {
    public let prompt: SaveImportPrompt
    public let committing: Bool
    public let confirm: (SaveImportMode) -> Void
    public let cancel: () -> Void

    @State private var selectedMode: SaveImportMode

    public init(prompt: SaveImportPrompt, committing: Bool = false,
                confirm: @escaping (SaveImportMode) -> Void, cancel: @escaping () -> Void) {
        self.prompt = prompt
        self.committing = committing
        self.confirm = confirm
        self.cancel = cancel
        _selectedMode = State(initialValue: prompt.defaultMode)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(ShellStrings.text("Import save for “\(prompt.gameTitle)”"))
                .shellType(ShellType.pageTitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("saveImport.title")

            summaryCard

            if prompt.hasExistingSave {
                modeCard
            } else {
                Text(ShellStrings.text("This game has no local save on this device yet. The files will be imported directly."))
                    .shellType(ShellType.note)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("saveImport.freshNote")
            }

            actionButtons
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .onChange(of: prompt.token) { _, _ in
            selectedMode = prompt.defaultMode
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: sourceSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ShellPalette.cream)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.sourceName)
                        .shellType(ShellType.settingLabel)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("saveImport.sourceName")

                    HStack(spacing: 8) {
                        Text(sourceKindLabel)
                            .shellText(11.5, .semibold, relativeTo: .caption)
                            .foregroundStyle(ShellPalette.cream)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.08), in: Capsule())

                        Text(contentsLabel)
                            .shellType(ShellType.note)
                            .foregroundStyle(.white.opacity(0.76))
                            .accessibilityIdentifier("saveImport.contents")
                    }
                }
            }

            if let tid = prompt.jksvTitleID {
                Rectangle().fill(ShellPalette.hairline).frame(height: 1)
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ShellPalette.ready)
                        .accessibilityHidden(true)
                    Text(ShellStrings.text("JKSV Title ID matched: \(tid)"))
                        .shellText(13, .semibold, relativeTo: .footnote)
                        .foregroundStyle(ShellPalette.ready)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("saveImport.jksvVerified")
                }
            }

            if !prompt.targetFolders.isEmpty {
                Rectangle().fill(ShellPalette.hairline).frame(height: 1)
                Text(ShellStrings.text("Target folders: \(prompt.targetFolders.joined(separator: ", "))"))
                    .shellType(ShellType.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("saveImport.targetFolders")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shellCard()
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: ShellStrings.text("Import mode"))

            modeOption(
                mode: .replace,
                title: ShellStrings.text("Replace and back up existing save"),
                detail: ShellStrings.text("Backs up your current save to save-backups first, then replaces it with the imported files."),
                identifier: "saveImport.mode.replace",
                target: "svi.mode.replace"
            )

            modeOption(
                mode: .merge,
                title: ShellStrings.text("Merge and keep existing saves"),
                detail: ShellStrings.text("Backs up your current save first, then adds imported files without removing existing slots."),
                identifier: "saveImport.mode.merge",
                target: "svi.mode.merge"
            )
        }
    }

    private func modeOption(
        mode: SaveImportMode,
        title: String,
        detail: String,
        identifier: String,
        target: String
    ) -> some View {
        let selected = selectedMode == mode
        return Button {
            guard !committing else { return }
            selectedMode = mode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(selected ? ShellPalette.cream : .clear)
                    Circle()
                        .strokeBorder(selected ? ShellPalette.cream : .white.opacity(0.45), lineWidth: 1.5)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 22, height: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .shellText(15, .semibold)
                        .foregroundStyle(.white)
                    Text(detail)
                        .shellType(ShellType.note)
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? ShellPalette.cream.opacity(0.14) : ShellPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? ShellPalette.cream.opacity(0.85) : ShellPalette.hairline, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(committing)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
        .shellTarget(target, enabled: !committing, radius: 14) {
            selectedMode = mode
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                confirm(prompt.hasExistingSave ? selectedMode : .replace)
            } label: {
                HStack(spacing: 8) {
                    if committing {
                        ProgressView().controlSize(.small).tint(.black)
                    }
                    Text(confirmTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillStyle(expands: true))
            .disabled(committing)
            .accessibilityIdentifier("saveImport.confirm")
            .shellTarget("svi.confirm", enabled: !committing, radius: 25) {
                confirm(prompt.hasExistingSave ? selectedMode : .replace)
            }

            Button(action: cancel) {
                Text(ShellStrings.text("Cancel")).frame(maxWidth: .infinity)
            }
            .buttonStyle(ShellButtonStyle(fills: true))
            .disabled(committing)
            .accessibilityIdentifier("saveImport.cancel")
            .shellTarget("svi.cancel", enabled: !committing, action: cancel)
        }
        .padding(.top, 4)
    }

    private var sourceSymbol: String {
        switch prompt.sourceKind {
        case .jksvArchive, .zipArchive: "doc.zipper"
        case .folder: "folder"
        case .singleFile: "doc"
        }
    }

    private var sourceKindLabel: String {
        switch prompt.sourceKind {
        case .jksvArchive: ShellStrings.text("JKSV archive")
        case .zipArchive: ShellStrings.text("ZIP archive")
        case .folder: ShellStrings.text("Folder")
        case .singleFile: ShellStrings.text("Single file")
        }
    }

    private var contentsLabel: String {
        if prompt.fileCount == 1 {
            return ShellStrings.text("1 file · \(prompt.formattedSize)")
        }
        return ShellStrings.text("\(prompt.fileCount) files · \(prompt.formattedSize)")
    }

    private var confirmTitle: String {
        if committing {
            return ShellStrings.text("Importing…")
        }
        guard prompt.hasExistingSave else {
            return ShellStrings.text("Import save")
        }
        switch selectedMode {
        case .replace: return ShellStrings.text("Replace and import")
        case .merge: return ShellStrings.text("Merge and import")
        }
    }
}
