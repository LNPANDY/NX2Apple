import SwiftUI
import NXCore
import NXModel

/// Mac or iPhone, and for the iPhone the switch that decodes textures on the CPU. Observes the build store only.
package struct TargetCard: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer
    @Environment(\.launcherSectionTitleFont) private var titleFont

    package init(build: BuildStore) { self.build = build }

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("section.target")).font(titleFont).foregroundStyle(LauncherPalette.secondaryText)
                .padding(.leading, 2)
            HStack(spacing: 14) {
                targetCard(BuildTarget.mac, symbol: "desktopcomputer", title: "build.mac", note: "build.macNote")
                targetCard(BuildTarget.ios, symbol: "iphone", title: "build.ios", note: "build.iosNote")
            }
            // A Switch 2 game (#445): how far the engine's support goes, for the chosen target. Nothing is blocked: the engine
            // builds both, and one Switch 2 game ran on an iPhone, but no target is tested for every game.
            if build.isSwitch2Game {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(LauncherPalette.accent.opacity(0.7))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t(build.target == BuildTarget.mac ? "switch2.noteMac" : "switch2.noteIOS"))
                        Text(loc.t(build.gameFolder != nil ? "switch2.keysFolder" : "switch2.keysPackage"))   // #696: what the keys row asks for
                    }
                    .font(.manrope(12.5)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4).padding(.top, 2)
            }
            // A Mac app runs on this Mac's GPU, which always decodes BC textures: the switch is the iPhone's only.
            if build.target != BuildTarget.mac {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(loc.t("opt.bc")).font(.manrope(14))
                            Text(loc.t("opt.bc.note")).font(.manrope(12.5)).foregroundStyle(LauncherPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle(loc.t("opt.bc"), isOn: $build.bcOnCPU).toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(build.running)
                            .padTarget("set.build.bc", scope: "main", enabled: !build.running, activate: { if !build.running { build.bcOnCPU.toggle() } }, adjust: { _ in if !build.running { build.bcOnCPU.toggle() } })
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                }
                .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
                .padding(.top, 4)
            }
        }
    }

    private func targetCard(_ value: String, symbol: String, title: String, note: String) -> some View {
        let macOnlyBlocked = value == BuildTarget.ios && build.isMacNativeGamesSelected
        let selected = build.target == value && !macOnlyBlocked
        let displayNote = macOnlyBlocked ? "upstream.mngMacOnly" : note
        return Button { build.target = value } label: {
            LauncherTargetOptionLabel(title: loc.t(title), symbol: symbol, note: loc.t(displayNote), selected: selected)
        }
        .buttonStyle(.plain).disabled(build.running || macOnlyBlocked)
        .opacity(macOnlyBlocked ? 0.5 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padTarget("set.build.target." + value, scope: "main", radius: 14, enabled: !build.running && !macOnlyBlocked) { if !build.running && !macOnlyBlocked { build.target = value } }
    }
}

/// Shared destination-card face. Callers own selection and native button semantics.
package struct LauncherTargetOptionLabel: View {
    package init(title: String, symbol: String, note: String? = nil, badge: String? = nil, selected: Bool, height: CGFloat? = nil, titleAtBottom: Bool = false) {
        self.title = title; self.symbol = symbol; self.note = note; self.badge = badge; self.selected = selected; self.height = height; self.titleAtBottom = titleAtBottom
    }
    let title: String, symbol: String
    let note: String?, badge: String?
    let selected: Bool
    let height: CGFloat?
    let titleAtBottom: Bool
    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: symbol).font(.system(size: 26, weight: .light))
                    .foregroundStyle(selected ? LauncherPalette.accent : .secondary).accessibilityHidden(true)
                Spacer(minLength: 8)
                if let badge {
                    Text(badge).font(.manrope(11.5, .semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(LauncherPalette.ink(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(LauncherPalette.ink(0.12)))
                }
            }.frame(height: 32, alignment: .top)
            if titleAtBottom { Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.manrope(titleAtBottom ? 18 : 16, .semibold))
                if let note {
                    Text(note).font(.manrope(12.5)).foregroundStyle(LauncherPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).frame(height: height, alignment: .topLeading)
        .background(selected ? LauncherPalette.selectedFill : LauncherPalette.selectableFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? LauncherPalette.selectedBorder : LauncherPalette.selectableBorder, lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}
