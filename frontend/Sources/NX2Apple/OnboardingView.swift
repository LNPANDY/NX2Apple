import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher

/// The guided setup. One layout for every step (LNPANDY/NX2Apple#1458): the top bar with the wordmark and the step's name, one
/// content group (title, subtitle, the step's list, its action) at the same top inset on every step, so the title never moves,
/// and the wizard footer with Back, the step count and Continue.
@MainActor struct OnboardingView<Driver: OnboardingDriver>: View {
    @ObservedObject var driver: Driver
    var lang: Lang = .initial()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var padFocus: PadFocus
    @StateObject private var gamepad: LauncherGamepad
    @State private var pickerOpen = false
    @State private var pickingKeys = true
    @State private var detailsOpen = false
    @State private var xcodeOpen: Bool
    @State private var supportOpen: Bool
    @State private var keysHelpOpen = false
    @State private var keysHelpDismissedAt = Date.distantPast
    @State private var pickerError: String?
    @State private var selectedGames: Set<String> = []
    @State private var backwards = false
    @AccessibilityFocusState private var headingFocused: Bool

    /// `expandSetup` opens the Xcode step's two sections from the start (the state gallery shows their rows that way).
    init(driver: Driver, lang: Lang = .initial(), gamepad: LauncherGamepad? = nil, padFocus: PadFocus? = nil, expandSetup: Bool = false) {
        _padFocus = StateObject(wrappedValue: padFocus ?? PadFocus())
        _driver = ObservedObject(wrappedValue: driver)
        self.lang = lang
        _gamepad = StateObject(wrappedValue: gamepad ?? LauncherGamepad())
        _xcodeOpen = State(initialValue: expandSetup)
        _supportOpen = State(initialValue: expandSetup)
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
    /// Welcome and Done carry their one action in the content group, under the list. Every other step has Continue in the footer.
    private var primaryInContent: Bool { state.step == .welcome || state.step == .done }

    /// The content group's top inset: the same on every step of a window, a little more on a taller one, so the title of the next
    /// step lands where the last one was.
    static func topInset(for height: CGFloat) -> CGFloat {
        min(DS.Space.xl * 4, max(DS.Space.xl, (height - 440) / 2))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { space in
                ScrollViewReader { proxy in
                    ScrollView {
                        // A fixed column at a leading inset taken from the window, not centred in the scroll view: a long step
                        // that scrolls gets a narrower scroll content, and centring would move the title sideways.
                        let column = min(space.size.width, DS.Control.contentWidth)
                        contentGroup
                            .frame(width: max(0, column - 2 * DS.Space.xl), alignment: .leading)
                            .padding(.leading, (space.size.width - column) / 2 + DS.Space.xl)
                            .padding(.top, Self.topInset(for: space.size.height)).padding(.bottom, DS.Space.xl)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .id(state.step)
                            .transition(transition)
                    }
                    // a legacy scroller would take its width from a long step and move the column (and the title) sideways
                    .scrollIndicators(.hidden)
                    .onChange(of: padFocus.focused) { id in
                        guard let id, padFocus.scope == "onboarding",
                              id != "onboarding.back", id != "onboarding.later", !(id == "onboarding.primary" && !primaryInContent) else { return }
                        withAnimation(LauncherMotion.animation(.easeInOut(duration: 0.18), reduceMotion: reduceMotion)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }.clipped()
            footer
                .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.32), value: state.step)
        .font(DS.Font.body)
        .foregroundStyle(DS.Color.textPrimary)
        .background(DS.Color.background)
        .background(LauncherWindowChrome())
        .background(ConsoleKeyboardInput(perform: keyboardAction, accepts: { !pickerOpen && !keysHelpOpen && [.left, .right, .up, .down, .activate, .back].contains($0) }))
        .launcherAppearance()
        .ignoresSafeArea(.container, edges: .top)
        .tint(DS.Color.accent)
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

    // MARK: Top bar

    /// The main window's wordmark, a hairline and the step's name in quiet text, where the launcher has its tabs.
    private var topBar: some View {
        HStack(spacing: DS.Space.m) {
            LauncherWordmark()
            DS.Color.separator.frame(width: 1, height: DS.Space.m)
            Text(t("onboarding.step.\(state.step.rawValue)")).font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
                .accessibilityLabel(String(format: t("onboarding.stepCount"), state.step.index + 1, OnboardingStep.allCases.count))
            Spacer()
        }
        .padding(.leading, 90).padding(.trailing, DS.Space.xl).frame(height: 64)
        .background(TitlebarDoubleClick())
        .accessibilityIdentifier("onboarding.topBar")
    }

    // MARK: Content group

    private var contentGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t(state.step.titleKey)).font(DS.Font.largeTitle).tracking(DS.Font.largeTitleTracking)
                .foregroundStyle(DS.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(accessibilityStatus)
                .accessibilityFocused($headingFocused)
            Text(t("onboarding.\(state.step.rawValue).note"))
                .font(DS.Font.headline).foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.s)
            stepContent.padding(.top, DS.Space.xl)
            if let pickerError { DSInlineWarning(pickerError).padding(.top, DS.Space.s) }
            if primaryInContent {
                primaryButton.padding(.top, DS.Space.l)
            }
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
        case .done: OnboardingCheck(lang: lang).frame(width: 56, height: 56)   // in the list's place: the title stays where it is on every step
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        DSCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // A Mac older than NVN needs is a fact, not a gate: the row says so, setup goes on.
                OnboardingStatusRow(title: t("onboarding.require.mac"),
                                    detail: t(state.osTooOldForNVN ? "onboarding.nvn.os" : "onboarding.require.macNote"),
                                    status: state.osTooOldForNVN ? .problem : .met)
                OnboardingRowDivider()
                OnboardingStatusRow(title: t("onboarding.require.files"), detail: t("onboarding.require.filesNote"), status: .todo)
                if case let .requirements(free, needed) = state.welcome {
                    OnboardingRowDivider()
                    OnboardingStatusRow(title: t("onboarding.require.disk"), detail: String(format: t("onboarding.require.diskNote"), free, needed),
                                        status: state.welcome.hasSpace ? .met : .problem)
                    if !state.welcome.hasSpace {
                        DSInlineWarning(t("onboarding.require.diskWarning"))
                            .padding(.leading, OnboardingRowDivider.inset).padding(.trailing, DS.Space.m).padding(.bottom, DS.Space.s)
                    }
                }
            }
        }
    }

    // MARK: Platform

    private var platforms: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
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
                .padTarget("onboarding.platform.\(platform.rawValue)", scope: "onboarding", radius: DS.Radius.card) { driver.choosePlatform(platform) }
            }
        }
    }

    // MARK: Xcode

    private var supportStatus: OnboardingTaskState {
        let tasks = state.backgroundTasks.map { state.background[$0] ?? .queued }
        if let failed = tasks.first(where: { if case .failed = $0 { return true }; return false }) { return failed }
        if state.engineTransfer != nil || tasks.contains(where: { if case .running = $0 { return true }; return false }) { return .running(nil) }
        return tasks.allSatisfy(\.isDone) ? .done : .queued
    }

    /// A failure is said in the closed row itself: the player sees what went wrong without opening it.
    private var xcodeSubtitle: String {
        if case let .failed(failure) = state.xcode { return failure.message }
        return t(state.xcode.statusKey)
    }
    private var supportSubtitle: String {
        if case let .failed(failure) = supportStatus { return failure.message }
        return t(supportStatus.statusKey)
    }

    private var xcodeStatus: OnboardingStatus {
        switch state.xcode {
        case .ready: return .met
        case .checking, .downloading, .settingUp: return .working
        case .missing, .needsSetup: return .todo
        case .disconnected, .failed: return .problem
        }
    }

    private var xcode: some View {
        VStack(spacing: DS.Space.s) {
            setupSection("onboarding.xcode.section", subtitle: xcodeSubtitle, status: xcodeStatus, id: "onboarding.xcode", open: $xcodeOpen) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    switch state.xcode {
                    case .checking: note(t("onboarding.xcode.checkingNote"))
                    case .missing: note(t("onboarding.xcode.missingNote"))
                    case .disconnected: note(t("xcodeChoice.unavailable"))
                    case .downloading:
                        note(t("onboarding.xcode.downloadNote"))
                        waitingBar
                    case .needsSetup: note(t("onboarding.xcode.passwordNote"))
                    case .settingUp, .ready:
                        ForEach(state.setupTasks, id: \.self) { task in
                            taskRow(task.titleKey, status: state.setup[task] ?? (state.xcode == .ready ? .done : .queued))
                        }
                    case let .failed(failure): failureView(failure)
                    }
                    if state.xcodeTooOldForNVN, state.xcode != .checking { DSInlineWarning(t("onboarding.nvn.xcode")) }
                }
            }
            setupSection("onboarding.background.title", subtitle: supportSubtitle, status: OnboardingStatus(supportStatus), id: "onboarding.support", open: $supportOpen) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(state.backgroundTasks, id: \.self) { task in
                        taskRow(task.titleKey, status: state.background[task] ?? .queued, detail: state.backgroundDetails[task])
                    }
                    if let transfer = state.engineTransfer {
                        taskRow("onboarding.background.engine", status: .running(transfer.fraction), detail: transfer.detail)
                    }
                    note(t("onboarding.background.note"))
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    /// A section of the Xcode step: a row that opens its task list, with the section's one action at its trailing edge.
    private func setupSection<Content: View>(_ title: String, subtitle: String, status: OnboardingStatus, id: String, open: Binding<Bool>,
        @ViewBuilder content: () -> Content) -> some View {
        let toggle = {
            withAnimation(LauncherMotion.animation(.easeOut(duration: DS.Motion.standard), reduceMotion: reduceMotion)) { open.wrappedValue.toggle() }
            if !open.wrappedValue, id == "onboarding.xcode", padFocus.visible, padFocus.focused == "onboarding.details" {
                padFocus.focused = id
            }
        }
        return DSCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button(action: toggle) {
                        HStack(spacing: DS.Space.s) {
                            OnboardingStatusIcon(status: status, label: t("onboarding.running"))
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                Text(t(title)).font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                                Text(subtitle).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                .rotationEffect(.degrees(open.wrappedValue ? 90 : 0)).foregroundStyle(DS.Color.symbolDefault).accessibilityHidden(true)
                        }
                        .padding(.leading, DS.Space.m).padding(.trailing, DS.Space.s).padding(.vertical, DS.Space.m)
                        .frame(minHeight: 68)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(t(open.wrappedValue ? "onboarding.expanded" : "onboarding.collapsed"))
                    .padTarget(id, scope: "onboarding", radius: DS.Radius.card, activate: toggle)
                    if id == "onboarding.xcode" {
                        if state.xcode != .ready { xcodeAction.padding(.trailing, DS.Space.m) }
                    } else if state.backgroundFailed {
                        Button(t("onboarding.retry")) { driver.retry(.xcode) }
                            .buttonStyle(DSRowButtonStyle())
                            .padTarget("onboarding.support.action", scope: "onboarding") { driver.retry(.xcode) }
                            .padding(.trailing, DS.Space.m)
                    }
                }
                if open.wrappedValue {
                    OnboardingRowDivider()
                    content()
                        .padding(.leading, OnboardingRowDivider.inset).padding(.trailing, DS.Space.m).padding(.vertical, DS.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private var xcodeAction: some View {
        switch state.xcode {
        case .missing, .needsSetup, .failed, .disconnected:
            Button(action: performXcodeAction) {
                Text(t(state.xcode == .missing ? "onboarding.getXcode" : state.xcode == .needsSetup ? "onboarding.xcode.prepare" : "onboarding.retry"))
            }
            .buttonStyle(DSRowButtonStyle())
            .padTarget("onboarding.xcode.action", scope: "onboarding", activate: performXcodeAction)
        case .checking, .downloading, .settingUp:
            // Only the download can be checked by hand; the other two show the same quiet label, disabled.
            Button(action: driver.recheckXcode) { Text(t("onboarding.xcode.waiting")) }
                .buttonStyle(DSRowButtonStyle()).disabled(state.xcode != .downloading)
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

    @ViewBuilder private var waitingBar: some View {
        if reduceMotion {
            Capsule().fill(DS.Color.surfaceRaised).frame(height: 4).accessibilityHidden(true)
        } else {
            LauncherProgressBar(value: nil, height: 4, tint: DS.Color.textPrimary).accessibilityHidden(true)
        }
    }

    private func taskRow(_ key: String, status: OnboardingTaskState, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                OnboardingStatusIcon(status: OnboardingStatus(status), label: t("onboarding.running"))
                Text(t(key)).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary)
                Spacer(minLength: 0)
                if case let .running(progress) = status, let progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(DS.Font.callout).monospacedDigit()
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            if case let .running(progress) = status, let progress {
                LauncherProgressBar(value: progress, height: 4, tint: DS.Color.textPrimary)
                    .padding(.leading, DS.Control.leadingSlot + DS.Space.s)
                    .transaction { if reduceMotion { $0.animation = nil } }
                    .accessibilityHidden(true)
            }
            if case .running = status, let detail, !detail.isEmpty {
                Text(detail).font(DS.Font.footnote).monospacedDigit().foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                    .padding(.leading, DS.Control.leadingSlot + DS.Space.s)
            }
            if case let .failed(failure) = status {
                Text(failure.message).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DS.Control.leadingSlot + DS.Space.s)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(t(status.statusKey) + progressText(status))
    }

    private func progressText(_ status: OnboardingTaskState) -> String {
        if case let .running(progress) = status, let progress { return ", \(Int(progress * 100))%" }
        return ""
    }

    /// The message is the row's subtitle already: the open section adds the diagnostic log, when there is one.
    @ViewBuilder private func failureView(_ failure: OnboardingFailure) -> some View {
        if failure.details.isEmpty {
            note(failure.message)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Button { detailsOpen.toggle() } label: {
                    Label(t(detailsOpen ? "onboarding.hideDetails" : "onboarding.showDetails"), systemImage: detailsOpen ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(DSRowButtonStyle())
                .accessibilityValue(t(detailsOpen ? "onboarding.expanded" : "onboarding.collapsed"))
                .padTarget("onboarding.details", scope: "onboarding") { detailsOpen.toggle() }
                if detailsOpen {
                    Text(failure.details).font(DS.Font.mono).foregroundStyle(DS.Color.textSecondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.s).background(DS.Color.background, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                }
            }
        }
    }

    // MARK: Keys and games

    private var keys: some View {
        OnboardingKeysContent(state: state, lang: lang, helpOpen: $keysHelpOpen,
            choose: { pickingKeys = true; pickerOpen = true }, receive: driver.chooseKeys, skip: skipKeys)
    }

    private var games: some View {
        OnboardingGamesContent(state: state, lang: lang, selected: $selectedGames,
            choose: { pickingKeys = false; pickerOpen = true }, receive: driver.chooseGames,
            build: { backwards = false; driver.buildGames(selectedGames) })
    }

    // MARK: Footer

    private var footerEnabled: Bool { state.primaryEnabled && (state.step != .xcode || state.canAdvance) }

    private var primaryTitle: String {
        switch state.step {
        case .xcode: return t("onboarding.continue")
        case .keys: return t("onboarding.confirmKeys")
        default: return t(state.primaryKey)
        }
    }

    /// The step's one primary action: in the content group on Welcome and Done, in the footer everywhere else.
    private var primaryButton: some View {
        Button(action: primaryAction) { DSContinueLabel(primaryTitle) }
            .buttonStyle(DSPrimaryButtonStyle()).disabled(!footerEnabled)
            .keyboardShortcut(.return, modifiers: [])
            .padTarget("onboarding.primary", scope: "onboarding", focusColor: DS.Color.accentOn, enabled: footerEnabled) { if footerEnabled { primaryAction() } }
    }

    private var footer: some View {
        DSWizardFooter(progress: String(format: t("onboarding.stepCount"), state.step.index + 1, OnboardingStep.allCases.count)) {
            if state.step != .welcome {
                Button(t("onboarding.back"), action: goBack)
                    .padTarget("onboarding.back", scope: "onboarding", activate: goBack)
            }
            if state.step != .done {
                Button(t("onboarding.later"), action: driver.skipForLater)
                    .padTarget("onboarding.later", scope: "onboarding", activate: driver.skipForLater)
            }
        } trailing: {
            if !primaryInContent { primaryButton }
        }
        .buttonStyle(DSSecondaryButtonStyle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.footer")
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

// MARK: Shared pieces

/// Where a requirement or a task stands. One symbol each, the same on every step: met is a filled check in the success colour,
/// to do an empty circle, a problem the warning triangle, and work in progress a small spinner.
enum OnboardingStatus: Equatable {
    case met, todo, problem, working
    init(_ task: OnboardingTaskState) {
        switch task {
        case .done: self = .met
        case .queued: self = .todo
        case .running: self = .working
        case .failed: self = .problem
        }
    }
}

struct OnboardingStatusIcon: View {
    let status: OnboardingStatus
    var label: String = ""
    var body: some View {
        Group {
            switch status {
            case .met: Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Color.statusSuccess)
            case .todo: Image(systemName: "circle").foregroundStyle(DS.Color.symbolDefault)
            case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Color.statusWarning)
            case .working: DSSpinner(size: 12).accessibilityLabel(label).frame(width: 16, height: 16)
            }
        }
        .font(.system(size: 16, weight: .regular))
        .frame(width: DS.Control.leadingSlot, height: DS.Control.leadingSlot)
        .accessibilityHidden(status != .working)
    }
}

/// A row of a step's list: the status symbol in the leading slot, the title, one secondary line and an optional trailing control.
struct OnboardingStatusRow<Trailing: View>: View {
    let title: String
    let detail: String
    let status: OnboardingStatus
    var help: String = ""
    let trailing: Trailing
    init(title: String, detail: String, status: OnboardingStatus, help: String = "", @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.detail = detail; self.status = status; self.help = help; self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: DS.Space.s) {
            OnboardingStatusIcon(status: status)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(help)
            trailing
        }
        .padding(.leading, DS.Space.m).padding(.trailing, DS.Space.m).padding(.vertical, DS.Space.s)
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
    }
}

/// The hairline between two rows of a step's list, from where the row titles start.
struct OnboardingRowDivider: View {
    static let inset = DS.Space.m + DS.Control.leadingSlot + DS.Space.s
    var body: some View { DS.Color.separator.frame(height: 1).padding(.leading, Self.inset) }
}

extension OnboardingStatusRow where Trailing == EmptyView {
    init(title: String, detail: String, status: OnboardingStatus, help: String = "") {
        self.init(title: title, detail: detail, status: status, help: help) { EmptyView() }
    }
}

struct OnboardingDropZone: View {
    let label: String, chooseLabel: String, id: String
    let enabled: Bool
    let choose: () -> Void
    let receive: (URL) -> Void
    @State private var targeted = false
    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 20, weight: .regular))
                .foregroundStyle(targeted ? DS.Color.symbolAccent : DS.Color.symbolDefault).accessibilityHidden(true)
            Text(label).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(chooseLabel, action: choose).buttonStyle(DSRowButtonStyle())
                .accessibilityLabel(label + ". " + chooseLabel)
                .padTarget("onboarding.choose.\(id)", scope: "onboarding") { if enabled { choose() } }
        }
        .padding(DS.Space.l).frame(minHeight: 96)
        .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
            .strokeBorder(targeted ? DS.Color.accent : DS.Color.separator, style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
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

private struct OnboardingCheck: View {
    let lang: Lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false
    var body: some View {
        ZStack {
            Circle().strokeBorder(DS.Color.statusSuccess.opacity(0.35), lineWidth: 1.5)
            CheckStroke().trim(from: 0, to: reduceMotion || drawn ? 1 : 0)
                .stroke(DS.Color.statusSuccess, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .padding(DS.Space.m)
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

/// Demo exits stay in the mock shell; opening a demo never starts real launcher detection or work. `state` opens it at a step and
/// state of its own (the state gallery's scenes), `lang` is the app's language or the gallery's.
@MainActor struct OnboardingDemoHost: View {
    @StateObject private var driver: MockOnboardingDriver
    @StateObject private var padFocus = PadFocus()
    @StateObject private var gamepad = LauncherGamepad()
    private let lang: Lang
    private let expandSetup: Bool
    private let onComplete: ((OnboardingState) -> Void)?
    init(scenario: MockOnboardingDriver.Scenario, state: OnboardingState = MockOnboardingDriver.sampleState, lang: Lang = .initial(),
         animated: Bool = true, expandSetup: Bool = false, games: [OnboardingGame]? = nil, onComplete: ((OnboardingState) -> Void)? = nil) {
        self.onComplete = onComplete
        self.lang = lang
        self.expandSetup = expandSetup
        _driver = StateObject(wrappedValue: MockOnboardingDriver(scenario: scenario, state: state, lang: lang, animated: animated, sampleGames: games))
    }
    var body: some View {
        Group {
            if driver.state.exit == nil { OnboardingView(driver: driver, lang: lang, gamepad: gamepad, expandSetup: expandSetup) }
            else {
                VStack(spacing: DS.Space.l) {
                    Text(L10n.string(driver.state.exit == .later ? "onboarding.demo.paused" : "onboarding.demo.library", lang))
                        .font(DS.Font.largeTitle).tracking(DS.Font.largeTitleTracking)
                    Text(L10n.string("onboarding.demo.note", lang)).font(DS.Font.headline).foregroundStyle(DS.Color.textSecondary)
                    if driver.state.exit == .later {
                        Button(L10n.string("onboarding.demo.resume", lang), action: driver.resume)
                            .buttonStyle(DSSecondaryButtonStyle())
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
        .foregroundStyle(DS.Color.textPrimary).background(DS.Color.background)
        .background(LauncherWindowChrome()).launcherAppearance()
    }
}
