import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher

@MainActor struct OnboardingView<Driver: OnboardingDriver>: View {
    @ObservedObject var driver: Driver
    var lang: Lang = .initial()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var padFocus: PadFocus
    @StateObject private var gamepad: LauncherGamepad
    @State private var pickerOpen = false
    @State private var pickingKeys = true
    @State private var detailsOpen = false
    @State private var xcodeOpen = false
    @State private var supportOpen = false
    @State private var keysHelpOpen = false
    @State private var keysHelpDismissedAt = Date.distantPast
    @State private var pickerError: String?
    @State private var selectedGames: Set<String> = []
    @State private var backwards = false
    @AccessibilityFocusState private var headingFocused: Bool

    init(driver: Driver, lang: Lang = .initial(), gamepad: LauncherGamepad? = nil, padFocus: PadFocus? = nil) {
        _padFocus = StateObject(wrappedValue: padFocus ?? PadFocus())
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
        GeometryReader { window in
            VStack(spacing: 0) {
                if state.step == .keys || state.step == .games {
                    compactImport(width: window.size.width)
                } else {
                // Setup needs room for its forms rather than the Library's expanding artwork showcase.
                onboardingHero(width: window.size.width, height: 300)
                GeometryReader { space in
                    ScrollViewReader { proxy in
                        ScrollView {
                            stepContent
                                .padding(.horizontal, 40).padding(.vertical, 32)
                                .frame(maxWidth: 900, alignment: .leading)
                                .frame(maxWidth: .infinity, minHeight: space.size.height, alignment: .center)
                                .id(state.step)
                                .transition(transition)
                        }
                        .onChange(of: padFocus.focused) { id in
                            guard let id, padFocus.scope == "onboarding",
                                  id != "onboarding.primary", id != "onboarding.back" else { return }
                            withAnimation(LauncherMotion.animation(.easeInOut(duration: 0.18), reduceMotion: reduceMotion)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }.clipped()
                }
                footer
                    .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.32), value: state.step)
        .font(.manrope(14))
        .foregroundStyle(LauncherPalette.textStrong)
        .background(LauncherPalette.background)
        .background(LauncherWindowChrome())
        .background(ConsoleKeyboardInput(perform: keyboardAction, accepts: { !pickerOpen && !keysHelpOpen && [.left, .right, .up, .down, .activate, .back].contains($0) }))
        .launcherAppearance()
        .ignoresSafeArea(.container, edges: .top)
        .tint(LauncherPalette.accent)
        .frame(minWidth: 900, idealWidth: 1280, minHeight: 680, idealHeight: 900)
        .padScope("onboarding", padFocus)
        .environmentObject(padFocus)
        .onAppear {
            padFocus.scope = "onboarding"
            gamepad.perform = padAction
            headingFocused = true
        }
        .onDisappear { gamepad.deactivate() }
        .onChange(of: state.step) { _ in
            keysHelpOpen = false
            padFocus.scope = "onboarding"
            padFocus.focused = nil
            detailsOpen = false
            xcodeOpen = false
            supportOpen = false
            pickerError = nil
            selectedGames = []
            headingFocused = true
        }
        .onChange(of: keysHelpOpen) { open in
            if !open {
                keysHelpDismissedAt = Date()
                padFocus.scope = "onboarding"
                padFocus.focused = state.step == .keys && padFocus.visible ? "onboarding.keys.help" : nil
            }
        }
        .task(id: state.step == .done && state.done == .ready) {
            guard state.step == .done, state.done == .ready else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, state.step == .done else { return }
            driver.openLibrary()
        }
        .onChange(of: state.xcode) { value in
            if case .failed = value { return }
            detailsOpen = false
            if padFocus.focused == "onboarding.details" { padFocus.focused = "onboarding.xcode" }
            if [.checking, .settingUp, .ready].contains(value), padFocus.focused == "onboarding.xcode.action" {
                padFocus.focused = "onboarding.xcode"
            }
        }
        .onChange(of: supportStatus) { value in
            if case .failed = value { return }
            if padFocus.focused == "onboarding.support.action" { padFocus.focused = "onboarding.support" }
        }
        .onChange(of: accessibilityStatus) { status in
            guard !status.isEmpty else { return }
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: status, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        .fileImporter(isPresented: $pickerOpen, allowedContentTypes: pickingKeys ? [.data] : [.folder]) { result in
            switch result {
            case let .success(url): pickingKeys ? driver.chooseKeys(url) : driver.chooseGames(url)
            case .failure: pickerError = t("onboarding.chooseFailed")
            }
        }
    }

    private func onboardingHero(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            navigation
            heading
                .font(.manrope(min(50, max(40, width * 0.045)), .bold))
                .padding(.horizontal, 40).padding(.vertical, 24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .id(state.step)
                .transition(LibraryHeroTransition.blurredMetadata(reduceMotion: reduceMotion))
        }
        .frame(height: height)
        .background(LibraryFallbackArtwork(size: CGSize(width: width, height: height)))
        .accessibilityIdentifier("onboarding.hero")
    }

    private var navigation: some View {
        HStack(spacing: 22) {
            LauncherBrandMark()
            Divider().frame(height: 22)
            Text(t("onboarding.setup")).font(.manrope(14, .medium)).foregroundStyle(LauncherPalette.secondaryText)
            Spacer()
            if state.step == .keys {
                OnboardingKeysHelp(open: $keysHelpOpen, lang: lang, canSkip: state.canSkipKeys, skip: skipKeys)
            }
        }
        .padding(.leading, 90).padding(.trailing, 32).frame(height: 64)
        .background(TitlebarDoubleClick())
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.step == .done {
                OnboardingCheck(lang: lang).frame(width: 64, height: 64).padding(.bottom, 12)
            }
            Text(t(state.step.titleKey)).tracking(-1.3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(accessibilityStatus)
                .accessibilityFocused($headingFocused)
            Text(t("onboarding.\(state.step.rawValue).note"))
                .font(.manrope(17)).foregroundStyle(LauncherPalette.secondaryText)
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
        case .done: EmptyView()
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            requirement("onboarding.require.mac", value: t("onboarding.require.macNote"), okay: true)
            requirement("onboarding.require.files", value: t("onboarding.require.filesNote"), okay: nil)
            if case let .requirements(free, needed) = state.welcome {
                requirement("onboarding.require.disk", value: String(format: t("onboarding.require.diskNote"), free, needed), okay: state.welcome.hasSpace)
                if !state.welcome.hasSpace {
                    Text(t("onboarding.require.diskWarning")).foregroundStyle(LauncherPalette.building)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // A fact about this Mac, constant during setup: a calm note, not a warning, and no gate.
            if state.osTooOldForNVN {
                Text(t("onboarding.nvn.os")).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.modifier(OnboardingCard())
    }

    private func requirement(_ key: String, value: String, okay: Bool?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: okay == true ? "checkmark.circle" : (okay == false ? "exclamationmark.triangle" : "folder"))
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(okay == false ? LauncherPalette.building : LauncherPalette.accent)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(t(key)).font(.manrope(15, .semibold))
                Text(value).foregroundStyle(LauncherPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }

    private var platforms: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(OnboardingPlatform.allCases, id: \.self) { platform in
                let selected = state.selectedPlatform == platform
                Button { driver.choosePlatform(platform) } label: {
                    LauncherTargetOptionLabel(title: t("onboarding.platform.\(platform.rawValue)"), symbol: platform.symbol,
                        badge: platform.includesIOS ? t("onboarding.platform.extraStorage") : nil, selected: selected, height: 180, titleAtBottom: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t("onboarding.platform.\(platform.rawValue)"))
                .accessibilityValue(platform.includesIOS ? t("onboarding.platform.extraStorage") : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .padTarget("onboarding.platform.\(platform.rawValue)", scope: "onboarding", radius: 14) { driver.choosePlatform(platform) }
            }
        }
    }

    private var supportStatus: OnboardingTaskState {
        let tasks = OnboardingBackgroundTask.allCases.map { state.background[$0] ?? .queued }
        if let failed = tasks.first(where: { if case .failed = $0 { return true }; return false }) { return failed }
        if state.engineTransfer != nil || tasks.contains(where: { if case .running = $0 { return true }; return false }) { return .running(nil) }
        return tasks.allSatisfy(\.isDone) ? .done : .queued
    }

    private var xcode: some View {
        VStack(spacing: 14) {
            setupAccordion("onboarding.xcode.section", subtitle: t(state.xcode.statusKey), id: "onboarding.xcode", open: $xcodeOpen) {
                xcodeIcon
            } content: {
                VStack(alignment: .leading, spacing: 16) {
                    switch state.xcode {
                    case .checking: Text(t("onboarding.xcode.checkingNote")).foregroundStyle(LauncherPalette.secondaryText)
                    case .missing: Text(t("onboarding.xcode.missingNote")).foregroundStyle(LauncherPalette.secondaryText)
                    case .disconnected: Text(t("xcodeChoice.unavailable")).foregroundStyle(LauncherPalette.secondaryText)
                    case .downloading:
                        Text(t("onboarding.xcode.downloadNote")).foregroundStyle(LauncherPalette.secondaryText)
                        waitingBar
                    case .needsSetup: Text(t("onboarding.xcode.passwordNote")).foregroundStyle(LauncherPalette.secondaryText)
                    case .settingUp, .ready:
                        ForEach(state.setupTasks, id: \.self) { task in
                            taskRow(task.titleKey, status: state.setup[task] ?? (state.xcode == .ready ? .done : .queued))
                        }
                    case let .failed(failure): failureView(failure)
                    }
                    if state.xcodeTooOldForNVN, state.xcode != .checking {
                        Text(t("onboarding.nvn.xcode")).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            setupAccordion("onboarding.background.title", subtitle: t(supportStatus.statusKey), id: "onboarding.support", open: $supportOpen) {
                statusIcon(supportStatus)
            } content: {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(OnboardingBackgroundTask.allCases, id: \.self) { task in
                        taskRow(task.titleKey, status: state.background[task] ?? .queued, detail: state.backgroundDetails[task])
                    }
                    if let transfer = state.engineTransfer {
                        taskRow("onboarding.background.engine", status: .running(transfer.fraction), detail: transfer.detail)
                    }
                    Text(t("onboarding.background.note")).font(.manrope(12)).foregroundStyle(LauncherPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func setupAccordion<Icon: View, Content: View>(_ title: String, subtitle: String, id: String, open: Binding<Bool>,
        @ViewBuilder icon: () -> Icon, @ViewBuilder content: () -> Content) -> some View {
        let toggle = {
            withAnimation(LauncherMotion.animation(.easeOut(duration: 0.18), reduceMotion: reduceMotion)) { open.wrappedValue.toggle() }
            if !open.wrappedValue, id == "onboarding.xcode", padFocus.visible, padFocus.focused == "onboarding.details" {
                padFocus.focused = id
            }
        }
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: toggle) {
                    HStack(spacing: 12) {
                        icon().frame(width: 52, height: 52)
                            .background(LauncherPalette.ink(0.08), in: RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t(title)).font(.manrope(14, .semibold))
                            Text(subtitle).font(.manrope(13)).foregroundStyle(LauncherPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .rotationEffect(.degrees(open.wrappedValue ? 90 : 0)).foregroundStyle(LauncherPalette.secondaryText).accessibilityHidden(true)
                    }.padding(18).contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityValue(t(open.wrappedValue ? "onboarding.expanded" : "onboarding.collapsed"))
                .padTarget(id, scope: "onboarding", radius: 14, activate: toggle)
                if id == "onboarding.xcode" {
                    if state.xcode != .ready { xcodeAction.padding(.trailing, 18) }
                } else if state.backgroundFailed {
                    Button(t("onboarding.retry")) { driver.retry(.xcode) }
                        .buttonStyle(LauncherSecondaryButtonStyle())
                        .padTarget("onboarding.support.action", scope: "onboarding") { driver.retry(.xcode) }
                        .padding(.trailing, 18)
                }
            }
            if open.wrappedValue {
                Divider().padding(.horizontal, 18)
                content().padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.ink(0.08)))
    }

    @ViewBuilder private var xcodeAction: some View {
        switch state.xcode {
        case .missing, .needsSetup, .failed, .disconnected:
            Button(action: performXcodeAction) {
                Text(t(state.xcode == .missing ? "onboarding.getXcode" : state.xcode == .needsSetup ? "onboarding.xcode.prepare" : "onboarding.retry"))
                    .frame(minWidth: 90)
            }
            .buttonStyle(LauncherSecondaryButtonStyle())
            .padTarget("onboarding.xcode.action", scope: "onboarding", activate: performXcodeAction)
        case .checking, .downloading, .settingUp:
            Button(action: driver.recheckXcode) {
                HStack(spacing: 8) {
                    OnboardingWaiting(label: t("onboarding.running")).frame(width: 14, height: 14).accessibilityHidden(true)
                    Text(t("onboarding.xcode.waiting"))
                }
                .font(.manrope(13, .semibold)).padding(.horizontal, 15)
                .frame(minWidth: 120, minHeight: LauncherControl.height).contentShape(Capsule())
            }
            .buttonStyle(.plain).launcherHover().disabled(state.xcode != .downloading)
            .padTarget("onboarding.xcode.action", scope: "onboarding", enabled: state.xcode == .downloading, activate: driver.recheckXcode)
        case .ready: EmptyView()
        }
    }

    private func performXcodeAction() {
        switch state.xcode {
        case .missing: driver.getXcode()
        case .needsSetup: driver.finishXcodeSetup()
        default: driver.retry(.xcode)
        }
    }

    @ViewBuilder private var xcodeIcon: some View {
        switch state.xcode {
        case .ready: statusIcon(.done)
        case .checking, .downloading, .settingUp: statusIcon(.running(nil))
        default: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 24)).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func statusIcon(_ status: OnboardingTaskState) -> some View {
        switch status {
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(LauncherPalette.ready)
        case .running: OnboardingWaiting(label: t("onboarding.running")).frame(width: 24, height: 24)
        case .queued: Image(systemName: "clock.fill").font(.system(size: 24)).foregroundStyle(LauncherPalette.secondaryText)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 24)).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var waitingBar: some View {
        if reduceMotion {
            Capsule().fill(LauncherPalette.cream.opacity(0.2)).frame(height: 6).accessibilityHidden(true)
        } else {
            LauncherProgressBar(value: nil, height: 6, tint: LauncherPalette.cream).accessibilityHidden(true)
        }
    }

    private func taskRow(_ key: String, status: OnboardingTaskState, detail: String? = nil) -> some View {
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
                if case let .running(progress) = status, let progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.manrope(12, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(LauncherPalette.secondaryText)
                }
            }
            if case let .running(progress) = status, let progress {
                LauncherProgressBar(value: progress, height: 4, tint: LauncherPalette.cream)
                    .transaction { if reduceMotion { $0.animation = nil } }
                    .accessibilityHidden(true)
            }
            if case .running = status, let detail, !detail.isEmpty {
                Text(detail)
                    .font(.manrope(11.5))
                    .monospacedDigit()
                    .foregroundStyle(LauncherPalette.secondaryText)
                    .lineLimit(1)
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
                        .padding(12).background(LauncherPalette.well, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var keys: some View {
        OnboardingKeysContent(state: state, lang: lang,
            choose: { pickingKeys = true; pickerOpen = true }, receive: driver.chooseKeys)
    }

    private var games: some View {
        OnboardingGamesContent(state: state, lang: lang, selected: $selectedGames,
            choose: { pickingKeys = false; pickerOpen = true }, receive: driver.chooseGames,
            build: { backwards = false; driver.buildGames(selectedGames) })
    }

    private func compactImport(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            navigation
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 48) {
                        heading.font(.manrope(min(50, max(40, width * 0.045)), .bold))
                        stepContent
                    }
                    .padding(.horizontal, 40).padding(.top, 64).padding(.bottom, 32)
                    .frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
                    .id(state.step).transition(transition)
                }
                .onChange(of: padFocus.focused) { id in
                    guard let id, id.hasPrefix("onboarding.game.") else { return }
                    withAnimation(LauncherMotion.animation(.easeInOut(duration: 0.18), reduceMotion: reduceMotion)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background(alignment: .top) { LibraryFallbackArtwork(size: CGSize(width: width, height: 300)).frame(height: 300) }
    }

    private var footerEnabled: Bool { state.primaryEnabled && (state.step != .xcode || state.canAdvance) }

    private var footer: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(state.step.index + 1), total: Double(OnboardingStep.allCases.count))
                .progressViewStyle(OnboardingStepProgressStyle())
                .frame(height: 4)
                .accessibilityLabel(String(format: t("onboarding.stepCount"), state.step.index + 1, OnboardingStep.allCases.count))
                .accessibilityValue("")
                .accessibilityIdentifier("onboarding.progress")
            HStack(spacing: 24) {
                if state.step != .welcome {
                    Button(action: goBack) {
                        Label(t("onboarding.back"), systemImage: "chevron.left").frame(minWidth: 120)
                    }
                        .buttonStyle(LauncherSecondaryButtonStyle(height: LauncherHeroAction.height))
                        .padTarget("onboarding.back", scope: "onboarding", activate: goBack)
                }
                if let pickerError {
                    Text(pickerError).font(.manrope(12)).foregroundStyle(LauncherPalette.building)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if state.step != .done {
                    Button(t("onboarding.later"), action: driver.skipForLater)
                        .buttonStyle(LauncherSecondaryButtonStyle(height: LauncherHeroAction.height))
                        .padTarget("onboarding.later", scope: "onboarding", activate: driver.skipForLater)
                }
                if state.step == .keys {
                    Button(t("onboarding.keys.later"), action: skipKeys)
                        .buttonStyle(LauncherSecondaryButtonStyle(height: LauncherHeroAction.height)).disabled(!state.canSkipKeys)
                        .padTarget("onboarding.keys.later", scope: "onboarding", enabled: state.canSkipKeys, activate: skipKeys)
                }
                Button(action: primaryAction) {
                    HStack(spacing: 12) {
                        Text(t(state.step == .xcode ? "onboarding.finishSetup" : state.step == .keys ? "onboarding.confirmKeys" : state.primaryKey))
                        Image(systemName: state.step == .done ? "arrow.up.right" : "arrow.right").accessibilityHidden(true)
                    }
                    .font(.manrope(16, .semibold)).padding(.horizontal, 28)
                    .frame(minWidth: 150, minHeight: 44)
                    .contentShape(Capsule())
                }
                .buttonStyle(LauncherActionButtonStyle()).disabled(!footerEnabled)
                .keyboardShortcut(.return, modifiers: [])
                .padTarget("onboarding.primary", scope: "onboarding", enabled: footerEnabled) { if footerEnabled { primaryAction() } }
            }.padding(.horizontal, 40).padding(.vertical, 24).frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
        }.background(LauncherPalette.background)
    }

    private func skipKeys() { backwards = false; driver.skipKeys() }

    private func primaryAction() {
        guard footerEnabled else { return }
        backwards = false
        if state.step == .xcode { driver.next(); return }
        if state.step == .keys { driver.confirmKeys(); return }
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
    private func keyboardAction(_ input: ConsoleInput) {
        switch input {
        case .left: padAction(.left)
        case .right: padAction(.right)
        case .up: padAction(.up)
        case .down: padAction(.down)
        case .activate: padAction(.a)
        case .back: padAction(.b)
        default: break
        }
    }
    private func padAction(_ action: LauncherGamepad.Action) {
        guard !pickerOpen else { return }
        if action == .b {
            if keysHelpOpen { keysHelpOpen = false }
            else if Date().timeIntervalSince(keysHelpDismissedAt) > 0.2 { goBack() }
            return
        }
        if !padFocus.visible || padFocus.focused == nil {
            padFocus.show(default: state.step == .xcode ? "onboarding.xcode" : (state.step == .platform && state.selectedPlatform == nil ? "onboarding.platform.mac" : "onboarding.primary"))
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

private struct OnboardingCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(LauncherPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LauncherPalette.ink(0.08)))
    }
}

struct OnboardingDropZone: View {
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
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LauncherPalette.accent.opacity(targeted ? 0.8 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
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
            Circle().trim(from: 0.05, to: 0.76).stroke(LauncherPalette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
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
    private let onComplete: ((OnboardingState) -> Void)?
    init(scenario: MockOnboardingDriver.Scenario, games: [OnboardingGame]? = nil, onComplete: ((OnboardingState) -> Void)? = nil) {
        self.onComplete = onComplete
        _driver = StateObject(wrappedValue: MockOnboardingDriver(scenario: scenario, sampleGames: games))
    }
    var body: some View {
        Group {
            if driver.state.exit == nil { OnboardingView(driver: driver, lang: lang, gamepad: gamepad) }
            else {
                VStack(spacing: 24) {
                    Text(L10n.string(driver.state.exit == .later ? "onboarding.demo.paused" : "onboarding.demo.library", lang)).font(.manrope(32, .bold))
                    Text(L10n.string("onboarding.demo.note", lang)).foregroundStyle(LauncherPalette.secondaryText)
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
        .onChange(of: driver.state.exit) { exit in
            if exit == .library { onComplete?(driver.state) }
        }
        .frame(minWidth: 900, minHeight: 680)
        .foregroundStyle(LauncherPalette.text).background(LauncherPalette.background)
        .background(LauncherWindowChrome()).launcherAppearance()
    }
}

private struct OnboardingStepProgressStyle: ProgressViewStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            let color: Color = scheme == .dark ? LauncherPalette.cream : .black
            Rectangle().fill(color.opacity(0.12))
                .overlay(alignment: .leading) {
                    Rectangle().fill(color).frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
                }
        }
    }
}
