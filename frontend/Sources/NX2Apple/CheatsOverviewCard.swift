import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Summary counts computed from the current build's parsed cheat entries.
struct CheatsCapabilitySummary: Equatable {
    var dataReady = 0
    var codeBaked = 0
    var codeNeedsBake = 0
    var fixedHeapWarning = 0

    init(cheats: [CheatFiles.Cheat]) {
        for cheat in cheats where cheat.kind != .label && !cheat.broken && !cheat.pairOff {
            switch cheat.capability {
            case .dataReady: dataReady += 1
            case .codeBaked: codeBaked += 1
            case .codeNeedsBake: codeNeedsBake += 1
            case .fixedHeapWarning: fixedHeapWarning += 1
            }
        }
    }

    var totalActive: Int { dataReady + codeBaked + codeNeedsBake + fixedHeapWarning }
    var directReadyTotal: Int { dataReady + fixedHeapWarning }
    var allIOSReady: Bool { totalActive > 0 && codeNeedsBake == 0 }
}

/// Top overview card in Mac CheatsView showing four-tier iOS capability counts, 30s crash guard badge, and one-click fast bake CTA.
struct CheatsOverviewCard: View {
    @EnvironmentObject var loc: Localizer
    let summary: CheatsCapabilitySummary
    let showsIOSGuidance: Bool
    let canFastBake: Bool
    let fastBakeDisabledReason: String?
    let onFastBake: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .center, spacing: DS.Space.xs) {
                Image(systemName: summary.codeNeedsBake > 0 ? "bolt.shield.fill" : "checkmark.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(summary.codeNeedsBake > 0 ? DS.Color.statusWarning : DS.Color.statusReady)
                    .accessibilityHidden(true)
                Text(loc.t("cheats.overview.title"))
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.textPrimary)
                Spacer(minLength: DS.Space.xs)
                HStack(spacing: DS.Space.xxs) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Color.statusReady)
                        .accessibilityHidden(true)
                    Text(loc.t("cheats.overview.fuseBadge"))
                        .font(DS.Font.footnote)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                .padding(.horizontal, DS.Space.xs)
                .padding(.vertical, DS.Space.xxs)
                .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
            }

            DSFlowRow(spacing: DS.Space.xs) {
                if summary.dataReady > 0 {
                    CheatsCountPill(
                        symbol: "checkmark.circle.fill",
                        symbolColor: DS.Color.statusReady,
                        text: String(format: loc.t("cheats.stat.dataReady"), summary.dataReady)
                    )
                }
                if summary.codeBaked > 0 {
                    CheatsCountPill(
                        symbol: "cpu.fill",
                        symbolColor: DS.Color.symbolAccent,
                        text: String(format: loc.t("cheats.stat.codeBaked"), summary.codeBaked)
                    )
                }
                if summary.codeNeedsBake > 0 {
                    CheatsCountPill(
                        symbol: "bolt.fill",
                        symbolColor: DS.Color.statusWarning,
                        text: String(format: loc.t("cheats.stat.codeNeedsBake"), summary.codeNeedsBake)
                    )
                }
                if summary.fixedHeapWarning > 0 {
                    CheatsCountPill(
                        symbol: "exclamationmark.triangle.fill",
                        symbolColor: DS.Color.statusWarning,
                        text: String(format: loc.t("cheats.stat.fixedHeap"), summary.fixedHeapWarning)
                    )
                }
            }

            HStack(alignment: .center, spacing: DS.Space.s) {
                Text(guidanceText)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.xs)
                if showsIOSGuidance && summary.codeNeedsBake > 0 {
                    VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                        Button(action: onFastBake) {
                            HStack(spacing: DS.Space.xxs) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .accessibilityHidden(true)
                                Text(loc.t("cheats.fastBake"))
                                    .font(DS.Font.bodyStrong)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(LauncherPrimaryButtonStyle())
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(!canFastBake)
                        .padTarget("cheats.fastBake", scope: "cheats", focusColor: DS.Color.accentOn, enabled: canFastBake) {
                            if canFastBake { onFastBake() }
                        }
                        if let reason = fastBakeDisabledReason, !canFastBake {
                            Text(reason)
                                .font(DS.Font.footnote)
                                .foregroundStyle(DS.Color.textSecondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(summary.codeNeedsBake > 0 ? DS.Color.statusWarning.opacity(0.38) : DS.Color.separator, lineWidth: 1)
        )
    }

    private var guidanceText: String {
        if summary.codeNeedsBake > 0 {
            return String(format: loc.t("cheats.overview.needsBakeHint"), summary.codeNeedsBake)
        }
        if summary.codeBaked > 0 {
            return loc.t("cheats.overview.allBakedHint")
        }
        return loc.t("cheats.overview.allDataHint")
    }
}

/// Compact count pill inside the overview card.
struct CheatsCountPill: View {
    let symbol: String
    let symbolColor: Color
    let text: String

    var body: some View {
        HStack(spacing: DS.Space.xxs) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, DS.Space.xxs)
        .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.separator, lineWidth: 1))
    }
}

/// Trigger key-combo capsule (e.g. "Hold ZR + B") rendered beside a cheat title.
struct CheatTriggerKeyPill: View {
    @EnvironmentObject var loc: Localizer
    let combo: String

    var body: some View {
        HStack(spacing: DS.Space.xxs) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.Color.symbolAccent)
                .accessibilityHidden(true)
            Text(String(format: loc.t("cheats.holdKey"), combo))
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, 2)
        .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.separator, lineWidth: 1))
    }
}

/// Compact per-row capability tag (data ready, code baked, needs bake, or fixed heap warning).
struct CheatCapabilityTag: View {
    @EnvironmentObject var loc: Localizer
    let capability: CheatCapability

    var body: some View {
        HStack(spacing: DS.Space.xxs) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(loc.t(labelKey))
                .font(DS.Font.footnote)
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
    }

    private var symbolName: String {
        switch capability {
        case .dataReady: "circle.fill"
        case .codeBaked: "cpu.fill"
        case .codeNeedsBake: "bolt.circle.fill"
        case .fixedHeapWarning: "exclamationmark.triangle.fill"
        }
    }

    private var symbolColor: Color {
        switch capability {
        case .dataReady: DS.Color.statusReady
        case .codeBaked: DS.Color.symbolAccent
        case .codeNeedsBake: DS.Color.statusWarning
        case .fixedHeapWarning: DS.Color.statusWarning
        }
    }

    private var textColor: Color {
        switch capability {
        case .dataReady: DS.Color.textSecondary
        case .codeBaked: DS.Color.textPrimary
        case .codeNeedsBake: DS.Color.statusWarning
        case .fixedHeapWarning: DS.Color.statusWarning
        }
    }

    private var labelKey: String {
        switch capability {
        case .dataReady: "cheats.cap.dataReady"
        case .codeBaked: "cheats.cap.codeBaked"
        case .codeNeedsBake: "cheats.cap.codeNeedsBake"
        case .fixedHeapWarning: "cheats.cap.fixedHeap"
        }
    }
}
