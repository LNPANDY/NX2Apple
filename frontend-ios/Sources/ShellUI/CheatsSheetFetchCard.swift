import SwiftUI

/// Top online-fetch status card shown inside `CheatsSheetView` when a `.cheats-fetch.json` receipt exists.
struct CheatsFetchStatusCard: View {
    let receipt: GameCheatFetchReceipt
    var onReviewOnlineResult: (() -> Void)? = nil

    var body: some View {
        let style = statusStyle(for: receipt)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: style.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(style.color)
                    .accessibilityHidden(true)
                Text(style.title)
                    .shellType(ShellType.cardTitle)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("cheats.fetchTitle")
                Spacer(minLength: 8)
                if receipt.entryCount > 0 && (receipt.isFoundStatus || receipt.status == "preserved_user") {
                    Text(ShellStrings.text("\(receipt.entryCount) entries"))
                        .shellText(11.5, .semibold, relativeTo: .caption)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(ShellPalette.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(style.color.opacity(0.45), lineWidth: 1))
                }
            }

            if !receipt.sources.isEmpty {
                Text(ShellStrings.text("Source: \(receipt.sources.joined(separator: ", "))"))
                    .shellType(ShellType.note)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let hint = style.hint {
                Text(hint)
                    .shellType(ShellType.note)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if receipt.fetchedAt > 0 {
                let formattedDate = Date(timeIntervalSince1970: receipt.fetchedAt)
                    .formatted(date: .abbreviated, time: .shortened)
                Text(ShellStrings.text("Updated \(formattedDate)"))
                    .shellText(11.5, .medium, relativeTo: .caption)
                    .foregroundStyle(.secondary)
            }

            if receipt.status == "preserved_user", let onReviewOnlineResult {
                Button(action: onReviewOnlineResult) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text(ShellStrings.text("Review online result"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ShellButtonStyle(fills: true))
                .padding(.top, 2)
                .accessibilityIdentifier("cheats.reviewOnline")
                .shellTarget("cht.reviewOnline", action: onReviewOnlineResult)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(style.color.opacity(0.36), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cheats.fetchCard")
    }

    private func statusStyle(for receipt: GameCheatFetchReceipt) -> (color: Color, symbol: String, title: String, hint: String?) {
        switch receipt.status {
        case "found", "fetched":
            return (
                ShellPalette.ready,
                "checkmark.icloud.fill",
                ShellStrings.text("Online cheats synced"),
                nil
            )
        case "not_found":
            return (
                ShellPalette.muted,
                "magnifyingglass.circle",
                ShellStrings.text("No cheats found online"),
                ShellStrings.text("No matching cheats exist in the online database for this build.")
            )
        case "preserved_user":
            let hint = receipt.fileName.isEmpty
                ? ShellStrings.text("Your own cheat file was kept instead of overwriting it.")
                : ShellStrings.text("Kept your existing \(receipt.fileName) instead of overwriting it.")
            return (
                ShellPalette.attention,
                "person.crop.circle.badge.checkmark",
                ShellStrings.text("Custom cheat file kept"),
                hint
            )
        case "offline":
            return (
                ShellPalette.attention,
                "wifi.slash",
                ShellStrings.text("Offline, could not check online"),
                ShellStrings.text("Connect to the internet and tap Fetch online to try again.")
            )
        default:
            return (
                ShellPalette.attention,
                "exclamationmark.icloud.fill",
                ShellStrings.text("Online fetch unavailable"),
                nil
            )
        }
    }
}

/// Simple wrapping flow layout for capability pills and trigger key capsules inside `CheatsSheetView`.
struct CheatsTagFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                widest = max(widest, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        widest = max(widest, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: proposal.width.map { min($0, widest) } ?? widest, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
