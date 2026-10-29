import SwiftUI
import UniformTypeIdentifiers

@MainActor struct OnboardingView<Driver: OnboardingDriver>: View {
    @ObservedObject var driver: Driver
    var lang: Lang = .initial()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var padFocus = PadFocus()
    @StateObject private var gamepad: LauncherGamepad
    @State private var pickerOpen = false
    @State private var pickingKeys = true
    @State private var detailsOpen = false
    @State private var pickerError: String?
    @State private var backwards = false
    @AccessibilityFocusState private var headingFocused: Bool

    init(driver: Driver, lang: Lang = .initial(), gamepad: LauncherGamepad? = nil) {
        _driver = ObservedObject(wrappedValue: driver)
        self.lang = lang
        _gamepad = StateObject(wrappedValue: gamepad ?? LauncherGamepad())
    }

    private var state: OnboardingState { driver.state }
    private func t(_ key: String) -> String { L10n.string(key, lang) }
    private var accessibilityStatus: String {
        switch state.step {
        case .xcode: return t(state.xcode.statusKey)
        case .keys: return t(state.keys.statusKey)
        case .games:
            switch state.games {
            case .scanning: return t("onboarding.games.scanning")
            case let .found(games): return String(format: t("onboarding.games.count"), games.count)
            case .none: return t("onboarding.games.none")
            case .empty: return t("onboarding.games.drop")
            }
        default: return ""
        }
    }
    private var transition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: backwards ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: backwards ? .trailing : .leading).combined(with: .opacity))
    }

    var body: some View {
        VStack(spacing: 0) {
            navigation
                .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
            // The block sits in the middle of the space between header and footer; when it is taller than that space
            // it starts at the top and scrolls (the minimum height only ever adds room around a short block).
            GeometryReader { space in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        heading
                        stepContent
                    }
                    .frame(maxWidth: 880, alignment: .leading)
                    .padding(.horizontal, 56).padding(.vertical, 28)
                    .frame(maxWidth: .infinity, minHeight: space.size.height, alignment: .center)
                    .id(state.step)
                    .transition(transition)
                }
            }
            .clipped()
            footer
                .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.32), value: state.step)
        .font(.manrope(14))
        .foregroundStyle(.white)
        .background(LauncherPalette.background)
        .background(LauncherWindowChrome())
        .preferredColorScheme(.dark)
        .tint(LauncherPalette.cream)
        .frame(minWidth: 900, idealWidth: 1280, minHeight: 680, idealHeight: 900)
        .padScope("onboarding", padFocus)
        .environmentObject(padFocus)
        .onAppear {
            padFocus.scope = "onboarding"
            gamepad.perform = padAction
            headingFocused = true
        }
        .onDisappear { gamepad.perform = { _ in } }
        .onChange(of: state.step) { _ in
            padFocus.focused = nil
            detailsOpen = false
            pickerError = nil
            headingFocused = true
        }
        .onChange(of: accessibilityStatus) { status in
            guard !status.isEmpty else { return }
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: status, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        .onExitCommand { goBack() }
        .fileImporter(isPresented: $pickerOpen, allowedContentTypes: pickingKeys ? [.data] : [.folder]) { result in
            switch result {
            case let .success(url): pickingKeys ? driver.chooseKeys(url) : driver.chooseGames(url)
            case .failure: pickerError = t("onboarding.chooseFailed")
            }
        }
    }

    private var navigation: some View {
        HStack {
            Group {
                if state.step != .welcome {
                    Button(action: goBack) { Label(t("onboarding.back"), systemImage: "chevron.left") }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .padTarget("onboarding.back", scope: "onboarding", activate: goBack)
                } else { Color.clear.frame(height: 36) }
            }.frame(width: 130, alignment: .leading)
            Spacer()
            HStack(spacing: 10) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Capsule().fill(step == state.step ? LauncherPalette.cream : (step.index < state.step.index ? LauncherPalette.ready : Color.white.opacity(0.18)))
                        .frame(width: step == state.step ? 26 : 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: t("onboarding.stepCount"), state.step.index + 1, OnboardingStep.allCases.count))
            Spacer()
            Button(t("onboarding.later"), action: driver.skipForLater)
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .padTarget("onboarding.later", scope: "onboarding", activate: driver.skipForLater)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 12)
        .background(TitlebarDoubleClick())   // an empty part of the header acts as the title bar does
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.step == .done {
                OnboardingCheck(lang: lang).frame(width: 64, height: 64).padding(.bottom, 12)
            }
            Text(t(state.step.titleKey)).font(.manrope(44, .bold)).tracking(-1.3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(accessibilityStatus)
                .accessibilityFocused($headingFocused)
            Text(t("onboarding.\(state.step.rawValue).note"))
                .font(.manrope(17)).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var stepContent: some View {
        switch state.step {
        case .welcome: welcome
        case .platform: platforms
        case .xcode: xcode
        case .keys: keys
        case .games: games
        case .done:
            VStack(alignment: .leading, spacing: 18) {
                requirement("onboarding.done.platform", value: t("onboarding.platform.\(state.selectedPlatform?.rawValue ?? "mac")"), okay: true)
                requirement("onboarding.done.tools", value: t("onboarding.ready"), okay: true)
                requirement("onboarding.done.keys", value: t("onboarding.keys.valid"), okay: true)
            }.modifier(OnboardingCard())
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            requirement("onboarding.require.mac", value: t("onboarding.require.macNote"), okay: true)
            requirement("onboarding.require.files", value: t("onboarding.require.filesNote"), okay: nil)
            if case let .requirements(free, needed) = state.welcome {
                requirement("onboarding.require.disk", value: String(format: t("onboarding.require.diskNote"), free, needed), okay: state.welcome.hasSpace)
                // Always laid out (shown only when short of room) so the centered block does not shift
                Text(t("onboarding.require.diskWarning")).foregroundStyle(LauncherPalette.building)
                    .opacity(state.welcome.hasSpace ? 0 : 1).accessibilityHidden(state.welcome.hasSpace)
            }
            // A fact about this Mac, constant during setup: a calm note, not a warning, and no gate.
            if state.osTooOldForNVN {
                Text(t("onboarding.nvn.os")).font(.manrope(13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.modifier(OnboardingCard())
    }

    private func requirement(_ key: String, value: String, okay: Bool?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: okay == true ? "checkmark.circle" : (okay == false ? "exclamationmark.triangle" : "folder"))
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(okay == false ? LauncherPalette.building : LauncherPalette.cream)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(t(key)).font(.manrope(15, .semibold))
                Text(value).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }

    private var platforms: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(OnboardingPlatform.allCases, id: \.self) { platform in
                let selected = state.selectedPlatform == platform
                Button { driver.choosePlatform(platform) } label: {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Image(systemName: platform.symbol).font(.system(size: 34, weight: .light))
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? LauncherPalette.cream : Color.white.opacity(0.2))
                        }.frame(height: 40, alignment: .top).accessibilityHidden(true)   // symbols differ in height: the titles stay on one line
                        Text(t("onboarding.platform.\(platform.rawValue)")).font(.manrope(22, .bold))
                        Text(t(platform.includesIOS ? "onboarding.platform.iosSize" : "onboarding.platform.macNote"))
                            .font(.manrope(13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(24).frame(maxWidth: .infinity, minHeight: 216, maxHeight: 216, alignment: .topLeading)
                    .background(selected ? LauncherPalette.cream.opacity(0.07) : LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? LauncherPalette.cream : Color.white.opacity(0.10), lineWidth: selected ? 2 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .padTarget("onboarding.platform.\(platform.rawValue)", scope: "onboarding", radius: 14) { driver.choosePlatform(platform) }
            }
        }
    }

    /// Both Xcode cards have this content height in every state (the tallest is setting up with the iOS sub-step), so nothing
    /// jumps when the state changes; content sits at the top and scrolls inside the card when it is longer.

    private func fixedCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content().frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: onboardingXcodeCardHeight, alignment: .top)
        .modifier(OnboardingCard())
    }

    private var xcode: some View {
        HStack(alignment: .top, spacing: 22) {
            fixedCard {
              VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    xcodeIcon
                    Text(t(state.xcode.statusKey)).font(.manrope(18, .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                switch state.xcode {
                case .checking: Text(t("onboarding.xcode.checkingNote")).foregroundStyle(.secondary)
                case .missing: Text(t("onboarding.xcode.missingNote")).foregroundStyle(.secondary)
                case .downloading:
                    Text(t("onboarding.xcode.downloadNote")).foregroundStyle(.secondary)
                    waitingBar
                case .needsSetup: Text(t("onboarding.xcode.passwordNote")).foregroundStyle(.secondary)
                case .settingUp, .ready:
                    ForEach(state.setupTasks, id: \.self) { task in
                        taskRow(task.titleKey, status: state.setup[task] ?? (state.xcode == .ready ? .done : .queued))
                    }
                case let .failed(failure): failureView(failure)
                }
                // Inside the fixed card (it scrolls when longer), so the card heights stay as they are.
                if state.xcodeTooOldForNVN, state.xcode != .checking {
                    Text(t("onboarding.nvn.xcode")).font(.manrope(12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
              }
            }
            fixedCard {
              VStack(alignment: .leading, spacing: 20) {
                Text(t("onboarding.background.title")).font(.manrope(14, .semibold))
                ForEach(OnboardingBackgroundTask.allCases, id: \.self) { task in
                    taskRow(task.titleKey, status: state.background[task] ?? .queued)
                }
                Text(t("onboarding.background.note")).font(.manrope(12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
        }
    }

    @ViewBuilder private var xcodeIcon: some View {
        switch state.xcode {
        case .ready: OnboardingCheck(lang: lang).frame(width: 26, height: 26)
        case .checking, .downloading, .settingUp: OnboardingWaiting(label: t("onboarding.running")).frame(width: 24, height: 24)
        default: Image(systemName: "hammer").foregroundStyle(LauncherPalette.cream).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var waitingBar: some View {
        if reduceMotion {
            Capsule().fill(LauncherPalette.cream.opacity(0.2)).frame(height: 6).accessibilityHidden(true)
        } else {
            LauncherProgressBar(value: nil, height: 6, tint: LauncherPalette.cream).accessibilityHidden(true)
        }
    }

    private func taskRow(_ key: String, status: OnboardingTaskState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    switch status {
                    case .done: OnboardingCheck(lang: lang)
                    case .running: OnboardingWaiting(label: t("onboarding.running"))
                    case .queued: Image(systemName: "circle").foregroundStyle(LauncherPalette.unbuilt)
                    case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(LauncherPalette.building)
                    }
                }.frame(width: 20, height: 20).accessibilityHidden(true)
                Text(t(key)).font(.manrope(13, .medium))
                Spacer(minLength: 0)
            }
            if case let .running(progress) = status, let progress {
                LauncherProgressBar(value: progress, height: 4, tint: LauncherPalette.cream)
                    .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
                    .accessibilityHidden(true)
            }
            if case let .failed(failure) = status {
                Text(failure.message).font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(t(status.statusKey) + progressText(status))
    }

    private func progressText(_ status: OnboardingTaskState) -> String {
        if case let .running(progress) = status, let progress { return ", \(Int(progress * 100))%" }
        return ""
    }

    private func failureView(_ failure: OnboardingFailure) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(failure.message).foregroundStyle(LauncherPalette.building).fixedSize(horizontal: false, vertical: true)
            if !failure.details.isEmpty {
                Button { detailsOpen.toggle() } label: {
                    Label(t(detailsOpen ? "onboarding.hideDetails" : "onboarding.showDetails"), systemImage: detailsOpen ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(LauncherSecondaryButtonStyle())
                .accessibilityValue(t(detailsOpen ? "onboarding.expanded" : "onboarding.collapsed"))
                .padTarget("onboarding.details", scope: "onboarding") { detailsOpen.toggle() }
                if detailsOpen {
                    Text(failure.details).font(.mono(11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// Content height of the keys card and the least of the games card, so their states do not resize them.

    private var keys: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if state.keys == .valid { OnboardingCheck(lang: lang).frame(width: 26, height: 26) }
                else if state.keys == .searching || state.keys == .validating {
                    OnboardingWaiting(label: t(state.keys.statusKey)).frame(width: 24, height: 24)
                } else { Image(systemName: "key").foregroundStyle(LauncherPalette.cream).accessibilityHidden(true) }
                Text(t(state.keys.statusKey)).font(.manrope(17, .semibold))
            }.accessibilityElement(children: .combine)
            if case let .found(url) = state.keys {
                Text(url.path).font(.mono(12)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case let .invalid(reason) = state.keys {
                Text(reason).foregroundStyle(LauncherPalette.building).fixedSize(horizontal: false, vertical: true)
            }
            if state.keys != .valid {
                dropZone(keys: true, enabled: state.keys != .validating)
            }
            Text(t("onboarding.keys.privacy")).font(.manrope(12)).foregroundStyle(.secondary)
        }
        .frame(minHeight: onboardingDropCardHeight, alignment: .topLeading)   // the same size whether it asks, checks or is done
        .modifier(OnboardingCard())
    }

    private var games: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch state.games {
            case .scanning:
                HStack(spacing: 12) {
                    OnboardingWaiting(label: t("onboarding.games.scanning")).frame(width: 24, height: 24)
                    Text(t("onboarding.games.scanning"))
                }
            case let .found(games) where !games.isEmpty:
                Text(String(format: t("onboarding.games.count"), games.count)).foregroundStyle(LauncherPalette.ready)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 290))], alignment: .leading, spacing: 22) {
                    ForEach(games) { game in
                        VStack(alignment: .leading, spacing: 8) {
                            // The collection's 1.8:1 crop, placeholder and radius, with driver-supplied artwork.
                            GeometryReader { geometry in
                                ZStack {
                                    if let cover = game.cover { Image(nsImage: cover).resizable().scaledToFill() }
                                    else {
                                        LauncherPalette.surface
                                        Image(systemName: "gamecontroller").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }.aspectRatio(1.8, contentMode: .fit).accessibilityHidden(true)
                            Text(game.title).font(.manrope(16, .semibold)).lineLimit(2)
                            if !game.version.isEmpty {
                                Text(String(format: t("onboarding.games.version"), game.version)).font(.manrope(12)).foregroundStyle(.secondary)
                            }
                        }.accessibilityElement(children: .combine)
                    }
                }
            case .none, .found:
                Label(t("onboarding.games.none"), systemImage: "folder.badge.questionmark").foregroundStyle(LauncherPalette.building)
                Text(t("onboarding.games.noneHint")).foregroundStyle(.secondary)
            case .empty: EmptyView()
            }
            dropZone(keys: false, enabled: state.games != .scanning)
        }
        .frame(minHeight: onboardingDropCardHeight, alignment: .topLeading)
    }

    private func dropZone(keys: Bool, enabled: Bool) -> some View {
        OnboardingDropZone(label: t(keys ? "onboarding.keys.drop" : "onboarding.games.drop"),
                           chooseLabel: t("onboarding.choose"), id: keys ? "keys" : "games", enabled: enabled,
                           choose: { pickingKeys = keys; pickerOpen = true },
                           receive: { url in keys ? driver.chooseKeys(url) : driver.chooseGames(url) })
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.3)
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("onboarding.footer")).font(.manrope(13)).foregroundStyle(.secondary)
                    if let pickerError { Text(pickerError).font(.manrope(12)).foregroundStyle(LauncherPalette.building) }
                }
                Spacer()
                Button(action: primaryAction) {
                    HStack(spacing: 12) {
                        Text(t(state.primaryKey))
                        Image(systemName: state.step == .done ? "arrow.up.right" : "arrow.right").accessibilityHidden(true)
                    }
                    .font(.manrope(16, .semibold)).padding(.horizontal, 28).padding(.vertical, 15)
                    .frame(minWidth: 190)
                    .foregroundStyle(state.primaryEnabled ? Color.black : Color.white.opacity(0.55))
                    .background(state.primaryEnabled ? LauncherPalette.cream : Color.white.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(!state.primaryEnabled)
                .keyboardShortcut(.return, modifiers: [])
                .padTarget("onboarding.primary", scope: "onboarding", radius: 28) { if state.primaryEnabled { primaryAction() } }
            }.padding(.horizontal, 56).padding(.vertical, 24)
        }
    }

    private func primaryAction() {
        guard state.primaryEnabled else { return }
        backwards = false
        switch state.primary {
        case .start: driver.start()
        case .next: driver.next()
        case .getXcode: driver.getXcode()
        case .finishXcodeSetup: driver.finishXcodeSetup()
        case .retry: driver.retry(state.step)
        case .confirmKeys: driver.confirmKeys()
        case .openLibrary: driver.openLibrary()
        case .waiting: break
        }
    }
    private func goBack() { backwards = true; driver.back() }
    private func padAction(_ action: LauncherGamepad.Action) {
        guard !pickerOpen else { return }
        if action == .b { goBack(); return }
        if !padFocus.visible {
            padFocus.show(default: "onboarding.primary")
            if [.up, .down, .left, .right].contains(action) { return }
        }
        switch action {
        case .up: padFocus.move(dx: 0, dy: -1)
        case .down: padFocus.move(dx: 0, dy: 1)
        case .left: padFocus.horizontal(-1)
        case .right: padFocus.horizontal(1)
        case .a: padFocus.activate()
        default: break
        }
    }
}

private let onboardingXcodeCardHeight: CGFloat = 270
private let onboardingDropCardHeight: CGFloat = 250

private struct OnboardingCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))
    }
}

private struct OnboardingDropZone: View {
    let label: String, chooseLabel: String, id: String
    let enabled: Bool
    let choose: () -> Void
    let receive: (URL) -> Void
    @State private var targeted = false
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 26, weight: .light)).accessibilityHidden(true)
            Text(label).font(.manrope(14)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(chooseLabel, action: choose).buttonStyle(LauncherSecondaryButtonStyle())
                .accessibilityLabel(label + ". " + chooseLabel)
                .padTarget("onboarding.choose.\(id)", scope: "onboarding") { if enabled { choose() } }
        }
        .padding(24).frame(minHeight: 112)
        .background(LauncherPalette.cream.opacity(targeted ? 0.10 : 0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LauncherPalette.cream.opacity(targeted ? 0.8 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
        .disabled(!enabled).opacity(enabled ? 1 : 0.5)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard enabled, let first = providers.first else { return false }
            _ = first.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return }
                DispatchQueue.main.async { receive(url) }
            }
            return true
        }
    }
}

private struct OnboardingWaiting: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            Circle().trim(from: 0.05, to: 0.76).stroke(LauncherPalette.cream, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(2)
                .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360))
        }.accessibilityLabel(label)
    }
}

private struct OnboardingCheck: View {
    let lang: Lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false
    var body: some View {
        ZStack {
            Circle().stroke(LauncherPalette.ready.opacity(0.25), lineWidth: 1)
            CheckStroke().trim(from: 0, to: reduceMotion || drawn ? 1 : 0)
                .stroke(LauncherPalette.ready, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .padding(5)
        }
        .accessibilityLabel(L10n.string("onboarding.ready", lang))
        .onAppear { withAnimation(.easeOut(duration: 0.3)) { drawn = true } }
    }
    private struct CheckStroke: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.77))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.9, y: rect.minY + rect.height * 0.22))
            }
        }
    }
}

/// Demo exits stay in the mock shell; opening a demo never starts real launcher detection or work.
@MainActor struct OnboardingDemoHost: View {
    @StateObject private var driver: MockOnboardingDriver
    @StateObject private var padFocus = PadFocus()
    @StateObject private var gamepad = LauncherGamepad()
    private let lang = Lang.initial()
    init(scenario: MockOnboardingDriver.Scenario) {
        _driver = StateObject(wrappedValue: MockOnboardingDriver(scenario: scenario))
    }
    var body: some View {
        Group {
            if driver.state.exit == nil { OnboardingView(driver: driver, lang: lang, gamepad: gamepad) }
            else {
                VStack(spacing: 24) {
                    Text(L10n.string(driver.state.exit == .later ? "onboarding.demo.paused" : "onboarding.demo.library", lang)).font(.manrope(32, .bold))
                    Text(L10n.string("onboarding.demo.note", lang)).foregroundStyle(.secondary)
                    if driver.state.exit == .later {
                        Button(L10n.string("onboarding.demo.resume", lang), action: driver.resume)
                            .buttonStyle(LauncherSecondaryButtonStyle())
                            .keyboardShortcut(.return, modifiers: [])
                            .padTarget("onboarding.resume", scope: "onboarding", activate: driver.resume)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padScope("onboarding", padFocus).environmentObject(padFocus)
                .onAppear { [driver, padFocus, gamepad] in
                    padFocus.scope = "onboarding"
                    // The flow releases its action on disappearance; install the exit screen's action after that.
                    DispatchQueue.main.async {
                        guard driver.state.exit != nil else { return }
                        gamepad.perform = { [weak driver, weak padFocus] action in
                            padFocus?.show(default: "onboarding.resume")
                            if action == .a { driver?.resume() }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 680)
        .foregroundStyle(.white).background(LauncherPalette.background)
        .background(LauncherWindowChrome()).preferredColorScheme(.dark)
    }
}
