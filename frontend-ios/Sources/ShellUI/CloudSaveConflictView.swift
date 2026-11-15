import SwiftUI

/// Modal confirmation card shown before launching a game when both the cloud save and this device's save changed since the
/// last sync, or when the cloud save cannot be read safely.
public struct CloudSaveConflictView: View {
    public let prompt: CloudSavePrompt
    public let decide: (CloudSaveDecision) -> Void

    public init(prompt: CloudSavePrompt, decide: @escaping (CloudSaveDecision) -> Void) {
        self.prompt = prompt
        self.decide = decide
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if prompt.isUnreadable {
                unreadableContent
            } else {
                conflictContent
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShellPalette.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var conflictContent: some View {
        HStack(spacing: 8) {
            Circle().fill(ShellPalette.attention).frame(width: 7, height: 7)
            Text(ShellStrings.text("Cloud saves").uppercased())
                .shellType(ShellType.eyebrow)
                .foregroundStyle(ShellPalette.attention)
        }
        Text(ShellStrings.text("Which save do you want to use?"))
            .shellType(ShellType.pageTitle)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("cloud.conflict.title")
        Text(ShellStrings.text("Both the cloud save and this device's save for \(prompt.gameTitle) changed since they were last in sync. The save you do not pick is backed up in save-backups."))
            .shellText(15)
            .foregroundStyle(.white.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("cloud.conflict.note")

        VStack(spacing: 10) {
            choiceCard(
                symbol: "icloud.and.arrow.down",
                title: ShellStrings.text("Use cloud save"),
                detail: ShellStrings.text("From \(prompt.cloudDevice.isEmpty ? "iCloud" : prompt.cloudDevice) · \(prompt.cloudSaved.isEmpty ? ShellStrings.text("unknown time") : prompt.cloudSaved)"),
                identifier: "cloud.conflict.useCloud",
                target: "cld.cloud"
            ) {
                decide(.useCloud)
            }

            choiceCard(
                symbol: "iphone",
                title: ShellStrings.text("Use this device's save"),
                detail: ShellStrings.text("On this device · \(prompt.localSaved.isEmpty ? ShellStrings.text("unknown time") : prompt.localSaved)"),
                identifier: "cloud.conflict.useDevice",
                target: "cld.local"
            ) {
                decide(.useDevice)
            }

            Button { decide(.cancel) } label: {
                Text(ShellStrings.text("Cancel"))
            }
            .buttonStyle(ShellButtonStyle(fills: true))
            .padding(.top, 2)
            .accessibilityIdentifier("cloud.conflict.cancel")
            .shellTarget("cld.cancel") { decide(.cancel) }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var unreadableContent: some View {
        HStack(spacing: 8) {
            Circle().fill(ShellPalette.attention).frame(width: 7, height: 7)
            Text(ShellStrings.text("Cloud saves").uppercased())
                .shellType(ShellType.eyebrow)
                .foregroundStyle(ShellPalette.attention)
        }
        Text(ShellStrings.text("Cloud save unavailable"))
            .shellType(ShellType.pageTitle)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("cloud.conflict.title")
        if !prompt.reason.isEmpty {
            Text(prompt.reason)
                .shellText(14, .semibold)
                .foregroundStyle(ShellPalette.attention)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cloud.conflict.reason")
        }
        Text(ShellStrings.text("The cloud save for \(prompt.gameTitle) could not be read right now. You can play with this device's save without overwriting the cloud file."))
            .shellText(15)
            .foregroundStyle(.white.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("cloud.conflict.note")

        VStack(spacing: 10) {
            Button { decide(.playOffline) } label: {
                Text(ShellStrings.text("Play with device save"))
            }
            .buttonStyle(PrimaryPillStyle(expands: true))
            .accessibilityIdentifier("cloud.conflict.offline")
            .shellTarget("cld.offline", radius: 25) { decide(.playOffline) }

            Button { decide(.cancel) } label: {
                Text(ShellStrings.text("Cancel"))
            }
            .buttonStyle(ShellButtonStyle(fills: true))
            .accessibilityIdentifier("cloud.conflict.cancel")
            .shellTarget("cld.cancel") { decide(.cancel) }
        }
        .padding(.top, 4)
    }

    private func choiceCard(symbol: String, title: String, detail: String, identifier: String,
                            target: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 38, height: 38)
                    .background(ShellPalette.cream, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .shellText(15.5, .bold)
                        .foregroundStyle(.white)
                    Text(detail)
                        .shellText(13)
                        .foregroundStyle(.white.opacity(0.66))
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShellPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
        .shellTarget(target, radius: 14, action: action)
    }
}

/// Confirmation card before replacing the current local save with the newest backup in `save-backups/`.
public struct RestoreSaveBackupView: View {
    public let game: GameTile
    public let backup: String
    public let restore: () -> Void
    public let cancel: () -> Void

    public init(game: GameTile, backup: String, restore: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.game = game
        self.backup = backup
        self.restore = restore
        self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ShellStrings.text("Restore save backup for “\(game.title)”?"))
                .shellType(ShellType.pageTitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("restore.title")
            Text(ShellStrings.text("Replaces this device's current save with the backup from \(backup). Your current save is backed up first."))
                .shellText(15)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("restore.note")
            VStack(spacing: 10) {
                Button(action: restore) {
                    Text(ShellStrings.text("Restore backup"))
                }
                .buttonStyle(PrimaryPillStyle(expands: true))
                .accessibilityIdentifier("restore.confirm")
                .shellTarget("rst.confirm", radius: 25, action: restore)

                Button(action: cancel) {
                    Text(ShellStrings.text("Cancel"))
                }
                .buttonStyle(ShellButtonStyle(fills: true))
                .accessibilityIdentifier("restore.cancel")
                .shellTarget("rst.cancel", action: cancel)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }
}

/// Calm, dismissible heads-up banner shown when the provisioning profile expires within 48 hours.
public struct SigningWarningBanner: View {
    public let warning: SigningWarning
    public var onDismiss: () -> Void

    public init(warning: SigningWarning, onDismiss: @escaping () -> Void = {}) {
        self.warning = warning
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ShellPalette.attention)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .shellText(13.5, .bold, relativeTo: .subheadline)
                    .foregroundStyle(ShellPalette.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("signing.headline")
                Text(ShellStrings.text("Refresh this app on your computer or signing tool soon. Your saves and game data stay safe."))
                    .shellText(12.5, .regular, relativeTo: .footnote)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("signing.note")
            }
            Spacer(minLength: 6)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ShellStrings.text("Close"))
            .accessibilityIdentifier("signing.dismiss")
            .shellTarget("lib.signing.dismiss", radius: 14, action: onDismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 540, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.62)))
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ShellPalette.attention.opacity(0.45), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("signing.banner")
    }

    private var headline: String {
        switch warning {
        case .expiringHours(let hours):
            ShellStrings.text("App signature expires in \(hours) hr")
        case .expiringSoon:
            ShellStrings.text("App signature expires in less than an hour")
        case .expired:
            ShellStrings.text("App signature has expired")
        }
    }
}

private struct ShellAskRestoreBackupKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((GameTile, String) -> Void)? = nil
}

extension EnvironmentValues {
    var shellAskRestoreBackup: ((GameTile, String) -> Void)? {
        get { self[ShellAskRestoreBackupKey.self] }
        set { self[ShellAskRestoreBackupKey.self] = newValue }
    }
}
