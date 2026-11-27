import SwiftUI

/// Interactive comparison sheet presented when online cheats are fetched while a user-owned `<BID>.txt` exists.
public struct CheatsOnlinePreviewSheet: View {
    public enum ViewMode: String, Equatable, Sendable {
        case list
        case raw
    }

    public let preview: GameCheatOnlinePreview
    public let applying: Bool
    public let errorMessage: String?
    public var onKeep: () -> Void
    public var onMerge: () -> Void
    public var onReplace: () -> Void

    @State private var mode: ViewMode = .list
    @State private var expandedEntryIDs: Set<String> = []
    @State private var focus = FocusAppearance(id: "chp.keep", visible: false)
    @State private var focusRefresh = 0
    @State private var targets = FocusTargetBuffer()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    public init(
        preview: GameCheatOnlinePreview,
        applying: Bool = false,
        errorMessage: String? = nil,
        onKeep: @escaping () -> Void,
        onMerge: @escaping () -> Void,
        onReplace: @escaping () -> Void
    ) {
        self.preview = preview
        self.applying = applying
        self.errorMessage = errorMessage
        self.onKeep = onKeep
        self.onMerge = onMerge
        self.onReplace = onReplace
    }

    private var isCompactHeight: Bool {
        verticalSizeClass == .compact
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summaryCard

                        if let errorMessage, !errorMessage.isEmpty {
                            errorBanner(errorMessage)
                        }

                        modePicker

                        if mode == .list {
                            listContent
                        } else {
                            rawContent
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }

                bottomActionBar
            }
            .background(ShellPalette.background)
            .navigationTitle(ShellStrings.text("Compare online cheats"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if !applying { onKeep() }
                    } label: {
                        Label(ShellStrings.text("Close"), systemImage: "xmark")
                    }
                    .disabled(applying)
                    .accessibilityIdentifier("cheats.preview.close")
                    .shellTarget("chp.close", enabled: !applying, radius: 22) {
                        if !applying { onKeep() }
                    }
                }
            }
        }
        .coordinateSpace(name: "shell")
        .environment(\.shellFocus, focus)
        .environment(\.shellFocusRefresh, focusRefresh)
        .onPreferenceChange(FocusTargets.self) { values in
            targets.values = values.filter { $0.frame.width > 1 }
        }
        .tint(ShellPalette.cream)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(applying)
        .modifier(ShellKeyboardNavigation(active: !applying) { action in
            handleKeyOrPad(action)
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cheats.preview.sheet")
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ShellPalette.cream)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ShellStrings.text("Local \(preview.localCount) vs Online \(preview.onlineCount)"))
                        .shellType(ShellType.cardTitle)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("cheats.preview.summary")
                    Text(ShellStrings.text("Your \(preview.fileName) has local edits or was imported manually. Choose how to apply the online version."))
                        .shellType(ShellType.note)
                        .foregroundStyle(.white.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !preview.sources.isEmpty {
                Text(ShellStrings.text("Source: \(preview.sources.joined(separator: ", "))"))
                    .shellType(ShellType.note)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            CheatsTagFlowLayout(spacing: 8) {
                diffPill(
                    color: preview.addedCount > 0 ? ShellPalette.ready : ShellPalette.muted,
                    symbol: "plus.circle.fill",
                    label: ShellStrings.text("+\(preview.addedCount) online new"),
                    identifier: "cheats.preview.addedCount"
                )
                diffPill(
                    color: ShellPalette.muted,
                    symbol: "equal.circle.fill",
                    label: ShellStrings.text("\(preview.sameNameCount) same name"),
                    identifier: "cheats.preview.sameCount"
                )
                diffPill(
                    color: preview.localOnlyCount > 0 ? ShellPalette.attention : ShellPalette.muted,
                    symbol: "person.crop.circle.fill",
                    label: ShellStrings.text("\(preview.localOnlyCount) local only"),
                    identifier: "cheats.preview.localOnlyCount"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shellCard()
    }

    private func diffPill(color: Color, symbol: String, label: String, identifier: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(label)
                .shellText(12, .semibold, relativeTo: .caption)
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(ShellPalette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DeleteStyle.red)
                .accessibilityHidden(true)
            Text(text)
                .shellType(ShellType.note)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeleteStyle.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DeleteStyle.red.opacity(0.4), lineWidth: 1))
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            modeButton(
                title: ShellStrings.text("List"),
                selected: mode == .list,
                identifier: "cheats.preview.modeList",
                target: "chp.mode.list"
            ) {
                mode = .list
                focusRefresh &+= 1
            }

            modeButton(
                title: ShellStrings.text("Raw text"),
                selected: mode == .raw,
                identifier: "cheats.preview.modeRaw",
                target: "chp.mode.raw"
            ) {
                mode = .raw
                focusRefresh &+= 1
            }
        }
        .padding(4)
        .background(ShellPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ShellPalette.hairline, lineWidth: 1))
    }

    private func modeButton(
        title: String,
        selected: Bool,
        identifier: String,
        target: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .shellText(13.5, .semibold, relativeTo: .subheadline)
                .foregroundStyle(selected ? .black : .white.opacity(0.84))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? ShellPalette.cream : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .shellTarget(target, radius: 9, action: action)
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(preview.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Rectangle().fill(ShellPalette.hairline).frame(height: 1).padding(.vertical, 8)
                }
                entryRow(entry)
            }
        }
        .shellCard()
    }

    private func entryRow(_ entry: GameCheatOnlineEntry) -> some View {
        let expanded = expandedEntryIDs.contains(entry.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleExpanded(entry.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.name)
                            .shellType(ShellType.settingLabel)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        CheatsTagFlowLayout(spacing: 6) {
                            statusBadge(isAdded: entry.isAdded)
                            if entry.isMaster {
                                Text(ShellStrings.text("Master"))
                                    .shellText(11, .semibold, relativeTo: .caption)
                                    .foregroundStyle(ShellPalette.cream)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(ShellPalette.cream.opacity(0.14), in: Capsule())
                            }
                            capabilityBadge(for: entry)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .accessibilityLabel(expanded ? ShellStrings.text("Hide code") : ShellStrings.text("Show code"))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cheats.preview.entry.\(entry.id)")
            .shellTarget("chp.entry.\(entry.id)", radius: 10) {
                toggleExpanded(entry.id)
            }

            if expanded {
                let codeText = entry.rawLines.isEmpty ? ShellStrings.text("No code lines") : entry.rawText
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: codeText)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("cheats.preview.entryCode.\(entry.id)")
                }
                .padding(10)
                .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShellPalette.hairline, lineWidth: 1))
            }
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(isAdded: Bool) -> some View {
        let color: Color = isAdded ? ShellPalette.ready : ShellPalette.muted
        let label = isAdded ? ShellStrings.text("New") : ShellStrings.text("Same name")
        return Text(label)
            .shellText(11, .semibold, relativeTo: .caption)
            .foregroundStyle(isAdded ? ShellPalette.ready : .white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
    }

    private func capabilityBadge(for entry: GameCheatOnlineEntry) -> some View {
        let style: (color: Color, symbol: String, label: String) = {
            if entry.isUnsafeCode {
                return (DeleteStyle.red, "shield.slash.fill", ShellStrings.text("Safety blocked"))
            }
            if entry.hasFixedAddress || entry.capability == .fixedHeapWarning {
                return (ShellPalette.attention, "exclamationmark.triangle.fill", ShellStrings.text("Fixed address · may break"))
            }
            switch entry.capability {
            case .dataReady:
                return (ShellPalette.ready, "circle.fill", ShellStrings.text("Direct on iPhone"))
            case .codeBaked:
                return (Color.cyan, "cpu.fill", ShellStrings.text("Code baked"))
            case .codeNeedsBake:
                return (Color.orange, "bolt.circle.fill", ShellStrings.text("Needs builder bake"))
            case .fixedHeapWarning:
                return (ShellPalette.attention, "exclamationmark.triangle.fill", ShellStrings.text("Fixed offset"))
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: style.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(style.color)
                .accessibilityHidden(true)
            Text(style.label)
                .shellText(11, .medium, relativeTo: .caption)
                .foregroundStyle(style.color.opacity(0.95))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(style.color.opacity(0.12), in: Capsule())
    }

    private var rawContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ShellStrings.text("Online \(preview.fileName) preview (read-only)"))
                .shellType(ShellType.note)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: preview.onlineText)
                    .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("cheats.preview.rawText")
            }
            .padding(12)
            .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ShellPalette.hairline, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shellCard()
    }

    private var bottomActionBar: some View {
        VStack(spacing: isCompactHeight ? 8 : 10) {
            Rectangle().fill(ShellPalette.hairline).frame(height: 1)

            if isCompactHeight {
                HStack(spacing: 10) {
                    keepButton
                    mergeButton
                    replaceButton
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            } else {
                VStack(spacing: 10) {
                    mergeButton
                    HStack(spacing: 10) {
                        keepButton
                        replaceButton
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
        .background(ShellPalette.surface.opacity(0.95))
    }

    private var keepButton: some View {
        Button {
            if !applying { onKeep() }
        } label: {
            Text(ShellStrings.text("Keep local"))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ShellButtonStyle(fills: true))
        .disabled(applying)
        .accessibilityIdentifier("cheats.preview.keep")
        .shellTarget("chp.keep", enabled: !applying) {
            if !applying { onKeep() }
        }
    }

    private var mergeButton: some View {
        let canMerge = preview.addedCount > 0 && !applying
        return Button {
            if canMerge { onMerge() }
        } label: {
            HStack(spacing: 6) {
                if applying {
                    ProgressView().controlSize(.small).tint(.black)
                }
                Text(ShellStrings.text("Merge new (+\(preview.addedCount))"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryPillStyle(expands: true))
        .disabled(!canMerge)
        .opacity(canMerge ? 1.0 : 0.42)
        .accessibilityIdentifier("cheats.preview.merge")
        .shellTarget("chp.merge", enabled: canMerge, radius: 25) {
            if canMerge { onMerge() }
        }
    }

    private var replaceButton: some View {
        Button {
            if !applying { onReplace() }
        } label: {
            Text(ShellStrings.text("Replace with online"))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ShellButtonStyle(fills: true, destructive: true))
        .disabled(applying)
        .accessibilityIdentifier("cheats.preview.replace")
        .shellTarget("chp.replace", enabled: !applying) {
            if !applying { onReplace() }
        }
    }

    private func toggleExpanded(_ id: String) {
        if expandedEntryIDs.contains(id) {
            expandedEntryIDs.remove(id)
        } else {
            expandedEntryIDs.insert(id)
        }
        focusRefresh &+= 1
    }

    private func handleKeyOrPad(_ action: ShellInput.Action) {
        focus.visible = true
        switch action {
        case .back:
            if !applying { onKeep() }
        case .activate:
            if let target = targets.values.first(where: { $0.id == focus.id }) {
                target.activate()
            }
        case .up, .down, .left, .right:
            let live = targets.values.filter { $0.id.hasPrefix("chp.") }
            focus.id = FocusNavigation.next(from: focus.id, action: action, targets: live)
        default:
            break
        }
    }
}
