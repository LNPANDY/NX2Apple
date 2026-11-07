import Foundation
import SwiftUI
import NXCore
import NXModel
import NXLauncher

/// Pokopia's LAN Link Play configuration; writes per-title env.txt outside the signed game app.
/// Both NX2Apple Play and directly opening the .app use the saved values on the next launch.
@MainActor struct LinkPlayCard: View {
    let game: LibraryGame
    @StateObject private var link: LinkPlayStore
    @State private var advancedOpen = false
    @EnvironmentObject private var loc: Localizer

    init(game: LibraryGame) {
        self.game = game
        _link = StateObject(wrappedValue: LinkPlayStore(titleID: game.titleID, appPath: game.appPath))
    }

    private var supported: Bool { LinkPlayCapability.supportedByApp(game.appPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("link.title")).font(.manrope(15, .semibold))
                .foregroundStyle(.secondary).padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                Toggle(loc.t("link.enable"), isOn: $link.config.enabled)
                    .toggleStyle(.switch)
                    .font(.manrope(14, .medium))
                    .padding(.horizontal, 18).padding(.vertical, 14)
                Text(loc.t("link.description"))
                    .font(.manrope(12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.bottom, 13)
                if link.config.enabled {
                    Divider().opacity(0.25).padding(.leading, 18)
                    field(loc.t("link.join"), placeholder: "192.168.1.25:47600", text: $link.config.joinAddress)
                    Text(loc.t("link.joinNote")).font(.manrope(11.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 18).padding(.bottom, 12)
                    Divider().opacity(0.25).padding(.leading, 18)
                    Toggle(loc.t("link.internet"), isOn: $link.config.internet)
                        .toggleStyle(.switch).font(.manrope(13.5))
                        .padding(.horizontal, 18).padding(.vertical, 13)
                    if link.config.internet {
                        Text(loc.t("link.internetWarning"))
                            .font(.manrope(12)).foregroundStyle(Color(red: 1, green: 0.78, blue: 0.24))
                            .padding(.horizontal, 18).padding(.bottom, 10)
                        field(loc.t("link.room"), placeholder: "XXXX-XXXX-XXXX-XXXX", text: $link.config.room)
                        field(loc.t("link.relay"), placeholder: "192.168.1.25:47610", text: $link.config.relayAddress)
                        Text(loc.t("link.roomNote")).font(.manrope(11.5)).foregroundStyle(.secondary)
                            .padding(.horizontal, 18).padding(.bottom, 12)
                    }
                    Divider().opacity(0.25).padding(.leading, 18)
                    Button { withAnimation(.easeInOut(duration: 0.18)) { advancedOpen.toggle() } } label: {
                        HStack(spacing: 8) {
                            Text(loc.t("link.advanced")).font(.manrope(14, .medium))
                            Spacer(minLength: 8)
                            Text(String(format: loc.t("launch.advancedCount"), 4))
                                .font(.manrope(12)).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(advancedOpen ? 90 : 0))
                        }
                        .padding(.horizontal, 18).frame(minHeight: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padTarget("link.advanced", scope: "launch", radius: 14) {
                        withAnimation(.easeInOut(duration: 0.18)) { advancedOpen.toggle() }
                    }
                    .onChange(of: link.config.story) { value in
                        if value { link.config.interact = true }
                    }
                    if advancedOpen {
                        VStack(alignment: .leading, spacing: 0) {
                            option(loc.t("link.discovery"), isOn: $link.config.discovery)
                            option(loc.t("link.tcp"), isOn: $link.config.tcpOnly)
                            option(loc.t("link.interact"), isOn: $link.config.interact)
                                .disabled(link.config.story)
                            option(loc.t("link.story"), isOn: $link.config.story)
                            Text(loc.t("link.storyWarning"))
                                .font(.manrope(11.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 18).padding(.bottom, 12)
                        }
                        .padding(.horizontal, 16).padding(.bottom, 12)
                    }
                }
                Divider().opacity(0.25).padding(.leading, 18)
                HStack {
                    Text(loc.t("link.nextLaunch")).font(.manrope(12)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(loc.t("link.apply")) { link.save() }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .padTarget("link.apply", scope: "launch") { if supported { link.save() } }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .disabled(!supported)
            .background(LauncherPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
            .onChange(of: link.config) { _ in link.edited() }
            if !supported {
                note(loc.t("link.rebuild"), problem: true)
            } else if let error = link.error {
                note(error, problem: true)
            } else if link.saved {
                note(loc.t("link.saved"), problem: false)
            } else {
                note(loc.t("link.status"), problem: false)
            }
        }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.manrope(13)).frame(width: 112, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.manrope(12.5))
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func option(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn).toggleStyle(.switch).font(.manrope(13))
            .padding(.horizontal, 2).padding(.vertical, 9)
    }

    private func note(_ value: String, problem: Bool) -> some View {
        Text(value).font(.manrope(12))
            .foregroundStyle(problem ? Color(red: 1, green: 0.78, blue: 0.24) : .secondary)
            .padding(.leading, 2).fixedSize(horizontal: false, vertical: true)
    }
}
