import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Online cheat database status card displaying `.cheats-fetch.json` receipt metadata (last checked time,
/// matched sources, entry count, preserved user file, not found, or offline).
struct CheatsFetchCard: View {
    @EnvironmentObject var loc: Localizer
    let receipt: CheatFetchReceipt?
    let hasBuildID: Bool
    let fetching: Bool

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.xs) {
                    Text(statusTitle)
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(1)
                    if let sourcesText, !sourcesText.isEmpty {
                        Text(sourcesText)
                            .font(DS.Font.footnote)
                            .foregroundStyle(DS.Color.textSecondary)
                            .padding(.horizontal, DS.Space.xs)
                            .padding(.vertical, 2)
                            .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.separator, lineWidth: 1))
                            .lineLimit(1)
                    }
                }
                Text(detailLine)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Space.xs)

            if fetching {
                ProgressView().controlSize(.small)
            } else if let timeText {
                Text(timeText)
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        if fetching { return "arrow.down.circle" }
        switch receipt?.statusKind {
        case .fetched: return "checkmark.icloud.fill"
        case .preservedUser: return "lock.doc.fill"
        case .notFound: return "magnifyingglass.circle"
        case .offline: return "wifi.slash"
        case .none: return "icloud.and.arrow.down"
        }
    }

    private var iconColor: Color {
        if fetching { return DS.Color.symbolAccent }
        switch receipt?.statusKind {
        case .fetched: return DS.Color.statusReady
        case .preservedUser: return DS.Color.symbolAccent
        case .notFound: return DS.Color.textSecondary
        case .offline: return DS.Color.statusWarning
        case .none: return DS.Color.symbolDefault
        }
    }

    private var borderColor: Color {
        if !fetching && receipt?.statusKind == .offline {
            return DS.Color.statusWarning.opacity(0.35)
        }
        return DS.Color.separator
    }

    private var statusTitle: String {
        if fetching { return loc.t("cheats.fetch.fetching") }
        switch receipt?.statusKind {
        case .fetched:
            return String(format: loc.t("cheats.fetch.statusFetched"), receipt?.entryCount ?? 0)
        case .preservedUser:
            return loc.t("cheats.fetch.statusPreserved")
        case .notFound:
            return loc.t("cheats.fetch.statusNotFound")
        case .offline:
            return loc.t("cheats.fetch.statusOffline")
        case .none:
            return loc.t("cheats.fetch.statusIdle")
        }
    }

    private var sourcesText: String? {
        guard let sources = receipt?.sources, !sources.isEmpty else { return nil }
        return sources.joined(separator: " + ")
    }

    private var detailLine: String {
        if fetching { return loc.t("cheats.fetch.fetchingDetail") }
        switch receipt?.statusKind {
        case .fetched:
            if let sources = sourcesText {
                return String(format: loc.t("cheats.fetch.detailFetched"), sources)
            }
            return loc.t("cheats.fetch.detailFetchedNoSource")
        case .preservedUser:
            return loc.t("cheats.fetch.detailPreserved")
        case .notFound:
            return loc.t("cheats.fetch.detailNotFound")
        case .offline:
            return loc.t("cheats.fetch.detailOffline")
        case .none:
            return hasBuildID ? loc.t("cheats.fetch.detailIdle") : loc.t("cheats.fetch.detailNoBuild")
        }
    }

    private var timeText: String? {
        guard let date = receipt?.fetchedDate else { return nil }
        return String(format: loc.t("cheats.fetch.checkedAt"), Self.dateFormatter.string(from: date))
    }
}
