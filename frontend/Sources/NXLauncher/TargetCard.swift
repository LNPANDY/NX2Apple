import SwiftUI
import NXCore
import NXModel

/// Mac or iPhone, and for the iPhone the switch that decodes textures on the CPU. Observes the build store only.
package struct TargetCard: View {
    @ObservedObject var build: BuildStore
    @EnvironmentObject var loc: Localizer

    package init(build: BuildStore) { self.build = build }

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("section.target")).font(.manrope(15, .semibold)).foregroundStyle(LauncherPalette.secondaryText)
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
        let selected = build.target == value
        return Button { build.target = value } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: symbol).font(.system(size: 26, weight: .light))
                        .foregroundStyle(selected ? LauncherPalette.accent : .secondary)
                    Spacer()
                    Circle().strokeBorder(selected ? LauncherPalette.radioOn : LauncherPalette.radioOff, lineWidth: selected ? 5 : 1.5)
                        .frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t(title)).font(.manrope(16, .semibold))
                    Text(loc.t(note)).font(.manrope(12.5)).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? LauncherPalette.selectedFill : LauncherPalette.selectableFill, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? LauncherPalette.selectedBorder : LauncherPalette.selectableBorder, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).disabled(build.running)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
