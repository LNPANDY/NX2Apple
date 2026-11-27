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
                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4).padding(.top, 2)
            }
            // A Mac app runs on this Mac's GPU, which always decodes BC textures: the switch is the iPhone's only.
            if build.target != BuildTarget.mac {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(loc.t("opt.bc")).font(.manrope(14))
                            Text(loc.t("opt.bc.note")).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle(loc.t("opt.bc"), isOn: $build.bcOnCPU).toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(build.running)
                            .padTarget("set.build.bc", scope: "main", enabled: !build.running, activate: { if !build.running { build.bcOnCPU.toggle() } }, adjust: { _ in if !build.running { build.bcOnCPU.toggle() } })
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    if build.showsIOSSeenShadersToggle, let info = build.cachedSeenShaders {
                        CardDivider()
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(loc.t("opt.iosSeenShaders")).font(.manrope(14))
                                Text(String(format: loc.t("opt.iosSeenShaders.note"), info.seenCount, info.totalCount))
                                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Toggle(loc.t("opt.iosSeenShaders"), isOn: $build.iosSeenShadersOnly)
                                .toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(build.running)
                                .padTarget("set.build.iosSeenShaders", scope: "main", enabled: !build.running,
                                           activate: { if !build.running { build.iosSeenShadersOnly.toggle() } },
                                           adjust: { _ in if !build.running { build.iosSeenShadersOnly.toggle() } })
                        }
                        .padding(.horizontal, 18).padding(.vertical, 14)
                    }
                    if build.supportsAutoFetchCheatsOption {
                        CardDivider()
                        autoFetchCheatsRow
                    }
                }
                .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
                .padding(.top, 4)
            } else if build.supportsAutoFetchCheatsOption || (build.buildUpstream == .nxnative && build.cachedSeenShaders != nil) {
                VStack(spacing: 0) {
                    if build.buildUpstream == .nxnative, let seenInfo = build.cachedSeenShaders {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(loc.t("opt.seenShaders")).font(.manrope(14))
                                Text(String(format: loc.t("opt.seenShaders.note"), seenInfo.seenCount.formatted(), seenInfo.totalCount.formatted()))
                                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Toggle(loc.t("opt.seenShaders"), isOn: $build.seenShadersOnly).toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(build.running)
                                .padTarget("set.build.seenShaders", scope: "main", enabled: !build.running,
                                           activate: { if !build.running { build.seenShadersOnly.toggle() } },
                                           adjust: { _ in if !build.running { build.seenShadersOnly.toggle() } })
                        }
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        if build.supportsAutoFetchCheatsOption {
                            CardDivider()
                        }
                    }
                    if build.supportsAutoFetchCheatsOption {
                        autoFetchCheatsRow
                    }
                }
                .background(LauncherPalette.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.cardBorder))
                .padding(.top, 4)
            }
        }
        .onAppear { build.refreshSeenShadersInfo() }
        .onChange(of: build.detectedGameTitleID16) { _ in build.refreshSeenShadersInfo() }
        .onChange(of: build.target) { _ in build.refreshSeenShadersInfo() }
        .onChange(of: build.buildUpstream) { _ in build.refreshSeenShadersInfo() }
    }

    private var autoFetchCheatsRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(loc.t("opt.autoFetchCheats")).font(.manrope(14))
                Text(loc.t("opt.autoFetchCheats.note"))
                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(loc.t("opt.autoFetchCheats"), isOn: $build.autoFetchCheats)
                .toggleStyle(LauncherSwitchStyle()).labelsHidden().disabled(build.running)
                .padTarget("set.build.autoFetchCheats", scope: "main", enabled: !build.running,
                           activate: { if !build.running { build.autoFetchCheats.toggle() } },
                           adjust: { _ in if !build.running { build.autoFetchCheats.toggle() } })
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func targetCard(_ value: String, symbol: String, title: String, note: String) -> some View {
        let macOnlyBlocked = value == BuildTarget.ios && build.isMacOnlyUpstreamSelected
        let selected = build.target == value && !macOnlyBlocked
        let displayNote = macOnlyBlocked ? build.macOnlyNoteKey : note
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
                Spacer(minLength: DS.Space.xs)
                if selected {   // the chosen card says so with a check, not only a border (#1458)
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(DS.Color.accent)
                        .accessibilityHidden(true)
                }
                if let badge {
                    Text(badge).font(.manrope(11.5, .semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(LauncherPalette.ink(0.06), in: Capsule())
                        .overlay(DSPill().strokeBorder(LauncherPalette.ink(0.12)))
                }
            }.frame(height: 32, alignment: .top)
            if titleAtBottom { Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(titleAtBottom ? DS.Font.headline : DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                if let note {
                    Text(note).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(DS.Space.l).frame(maxWidth: .infinity, alignment: .leading).frame(height: height, alignment: .topLeading)
        .background(selected ? LauncherPalette.selectedFill : LauncherPalette.selectableFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(selected ? DS.Color.accent : LauncherPalette.selectableBorder, lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
    }
}
