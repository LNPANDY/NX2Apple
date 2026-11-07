import SwiftUI
import ShellUI
import ShellControllers

@main struct ShellDemoApp: App {
    /// `--host`, or always when built with `-D HOST_DEFAULT` (a build to install, where no launch arguments can be passed).
    private var hostMode: Bool {
        #if HOST_DEFAULT
        !ProcessInfo.processInfo.arguments.contains("--samples")
        #else
        ProcessInfo.processInfo.arguments.contains("--host")
        #endif
    }
    var body: some Scene {
        WindowGroup {
            if hostMode { HostDemoScreen() } else { DemoScreen() }
        }
    }
}

/// The demo owns sample values. None of this state or callback simulation is part of ShellUI.
struct DemoScreen: View {
    @State private var padMap = PadMap()
    @State private var padSnapshot: PadSnapshot?
    @State private var games = SampleData.games
    @State private var notice: String?
    @State private var input = ShellInputLog()
    @State private var unfolded = ProcessInfo.processInfo.arguments.contains("--unfolded")
    /// Real controllers, through the reusable adapter in ShellControllers.
    @State private var gamepads = GamepadAdapter()
    @State private var connected: [ConnectedController] = []
    private var args: [String] { ProcessInfo.processInfo.arguments }
    private func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    private var scenario: String { value("--screen") ?? "library" }
    /// `--games` sizes the sample library, repeating fixtures for long-scroll checks.
    private var shown: [GameDetail] {
        guard scenario != "empty" else { return [] }
        guard let count = value("--games").flatMap(Int.init), !games.isEmpty else { return games }
        return (0..<max(0, count)).map { index in
            var detail = games[index % games.count]
            if index >= games.count {
                detail.game.id += "-\(index)"
                detail.game.recentlyPlayed = nil
            }
            return detail
        }
    }
    private var initialSelection: String {
        switch scenario {
        case "needs-data": "paper"
        case "needs-update": "moon"
        case "broken": "wild"
        default: value("--select") ?? "orbit"
        }
    }

    var body: some View {
        Group {
            if args.contains("--fold-test") { foldHarness } else { shell }
        }
        .background(ShellPalette.background)
        // QA only: on-screen stand-ins for controller buttons, above everything so the art never takes their taps.
        .overlay(alignment: .bottom) {
            if args.contains("--input-test") {
                HStack {
                    ForEach(["left", "right", "down", "up", "activate", "back", "settings"], id: \.self) { name in
                        Button(name) { send(qaAction(name)) }.accessibilityIdentifier("qa.input.\(name)").frame(minHeight: 44)
                    }
                }
                .font(.caption).padding(.horizontal, 12)
                .background(.black.opacity(0.8), in: Capsule())
                .padding(.bottom, 2)
            }
        }
        .alert("Demo action", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
        .onAppear {
            gamepads.onInput = { action, device in send(action, from: device) }
            gamepads.onRelease = { action, device in input.append(action, device: device, released: true) }
            gamepads.onControllersChange = { connected = $0 }
            gamepads.start()
        }
        .onDisappear { gamepads.stop() }
    }

    private var shell: some View {
        LibraryView(games: shown,
                    controllers: scenario == "controllers-empty" ? [] : controllers,
                    actions: actions, input: input, initialSelection: initialSelection,
                    initialDetailOpen: scenario == "settings",
                    initialControllersOpen: scenario.hasPrefix("controllers"),
                    initialShellSettingsOpen: scenario == "shell-settings",
                    initialFocusVisible: scenario == "focus", globalPadMap: padMap,
                    // The test's screen shows a few buttons held until a real controller moves.
                    padSnapshot: padSnapshot ?? (scenario == "controllers-test"
                        ? PadSnapshot(name: "Demo", pressed: [.a, .leftBumper, .up], leftStick: CGPoint(x: 0.6, y: 0.5), rightTrigger: 0.7) : nil),
                    initialPadMapping: scenario == "controllers-mapping" ? ControllersView.mappingID : nil,
                    initialButtonTestOpen: scenario == "controllers-test")
    }

    /// A stand-in for the foldable while no Simulator runtime for it is installed: the same running shell in a frame
    /// that switches between a short 1.4:1 phone screen (folded) and a larger, nearly square one (unfolded).
    /// The sizes are only this harness's. ShellUI decides from whatever size it gets.
    private var foldHarness: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let folded = landscape ? CGSize(width: 525, height: 375) : CGSize(width: 375, height: 525)
            let open = landscape ? CGSize(width: 890, height: 626) : CGSize(width: 626, height: 890)
            let size = unfolded ? open : folded
            VStack(spacing: 14) {
                Button(unfolded ? "Fold" : "Unfold") {
                    withAnimation(.smooth(duration: 0.45)) { unfolded.toggle() }
                }
                .accessibilityIdentifier("qa.fold").frame(minHeight: 44)
                shell
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.25)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func qaAction(_ name: String) -> ShellInput.Action {
        switch name {
        case "left": .left
        case "right": .right
        case "down": .down
        case "up": .up
        case "activate": .activate
        case "back": .back
        default: .settings
        }
    }
    private func send(_ action: ShellInput.Action, from device: InputDevice = .controller(.neutral)) {
        input.append(action, device: device)
    }
    /// The real controllers when any are connected, the sample ones otherwise.
    private var controllers: [ControllerInfo] {
        if !args.contains("--samples"), !connected.isEmpty {
            return connected.map { ControllerInfo(id: $0.id, name: $0.name, player: demoText("Player \($0.player)"),
                                                  batteryPercent: $0.batteryPercent, charging: $0.charging) }
        }
        return SampleData.controllers
    }
    private var actions: ShellActions {
        ShellActions(onPlay: { _ in notice = demoText("Play requested. The demo does not launch games.") },
                     onChange: { game, row, value in
            guard let g = games.firstIndex(where: { $0.id == game }) else { return }
            for section in games[g].sections.indices {
                if let index = games[g].sections[section].rows.firstIndex(where: { $0.id == row }) {
                    games[g].sections[section].rows[index].value = value
                    games[g].sections[section].rows[index].fromShell = false
                    games[g].hasModifiedSettings = true
                }
            }
        }, onPickGameData: { _ in notice = demoText("Choose game data requested. The host supplies the picker.") },
                     onUseAppData: { _ in notice = demoText("Use app data requested.") },
                     onPickCloudSaves: { _ in notice = demoText("Choose cloud folder requested. The host supplies the picker.") },
                     onDisableCloudSaves: { id in
            if let i = games.firstIndex(where: { $0.id == id }) { games[i].cloudSaves = nil; games[i].cloudFromShell = false; games[i].cloudCanUseShell = true }
        },
                     onResetDefaults: { id in
            if let i = games.firstIndex(where: { $0.id == id }), let original = SampleData.games.first(where: { $0.id == id }) {
                games[i].sections = original.sections
                games[i].hasModifiedSettings = false
            }
        }, onShowLog: { _ in notice = demoText("Show log requested. The host supplies the log.") },
                     onAppUpdate: { notice = demoText("App update requested. The host supplies update instructions.") },
                     onBack: { notice = demoText("Back requested.") },
                     onPickShellData: { notice = demoText("Choose game data requested. The host supplies the picker.") },
                     onPickShellCloud: { notice = demoText("Choose cloud folder requested. The host supplies the picker.") },
                     onUseShellCloud: { id in
            if let i = games.firstIndex(where: { $0.id == id }), let original = SampleData.games.first(where: { $0.id == id }) {
                games[i].cloudSaves = original.cloudSaves; games[i].cloudFromShell = true; games[i].cloudCanUseShell = false
            }
        }, onClearShellData: { ShellSettingsStore.current.clearDataFolderName() },
                     onClearShellCloud: { ShellSettingsStore.current.clearCloudSavesFolderName() },
                     onGlobalPadMapChange: { button, value in
            if button == "swapAB" { padMap.setSwapAB(value == "1") } else { padMap.set(button, to: value) }
        }, onGlobalPadMapReset: { padMap = PadMap() },
                     onButtonTest: { open in
            gamepads.onSnapshot = open ? { padSnapshot = $0 } : nil
            if !open { padSnapshot = nil }
        })
    }
}

#Preview("Library") { DemoScreen() }
#Preview("Cover Flow", traits: .landscapeLeft) { DemoScreen() }
#Preview("Game settings") {
    ScrollView { GameDetailView(detail: SampleData.games[0]).padding(24) }.background(ShellPalette.background).preferredColorScheme(.dark)
}
#Preview("Ready to play") { GameStateView(game: SampleData.games[0].game).padding().background(ShellPalette.background) }
#Preview("Needs game data") { GameStateView(game: SampleData.games[2].game).padding().background(ShellPalette.background) }
#Preview("Needs app update") { GameStateView(game: SampleData.games[3].game).padding().background(ShellPalette.background) }
#Preview("Broken") { GameStateView(game: SampleData.games[4].game).padding().background(ShellPalette.background) }
#Preview("Empty library") { LibraryView(games: []) }
#Preview("Controllers") { ControllersView(controllers: SampleData.controllers).background(ShellPalette.background) }
#Preview("No controllers") { ControllersView(controllers: []).background(ShellPalette.background) }
#Preview("Two panes", traits: .fixedLayout(width: 834, height: 1194)) { DemoScreen() }
#Preview("Folded", traits: .fixedLayout(width: 375, height: 525)) { DemoScreen() }
#Preview("Unfolded", traits: .fixedLayout(width: 626, height: 890)) { DemoScreen() }
#Preview("Largest text") { DemoScreen().environment(\.dynamicTypeSize, .accessibility5) }
