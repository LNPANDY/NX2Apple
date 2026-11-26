import AppKit
import SwiftUI
import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXModel
@testable import NXLauncher

/// Visual QA and pixel-alignment regression tests for `OutcomeCard` disclosure layout,
/// shell-updated status lines, and `CardDisclosure` siblings (`LogCard`, `InstallCard`).
@MainActor final class OutcomeDisclosureCaptureTests: IsolatedDefaultsTestCase {
    private func makeStores(lang: Lang, tempDir: URL) -> LauncherStores {
        let stores = LauncherStores(defaults: testDefaults)
        stores.localizer.lang = lang

        let build = stores.build
        build.home = tempDir.path
        build.target = BuildTarget.ios
        build.runningTarget = BuildTarget.ios
        build.installedOn = "qa-iphone"
        build.installedDataComplete = true
        build.shellUpdatedOnDevice = true
        build.archivePath = "/Volumes/Games/games/0100E65002BB8000"
        build.stages = [Stage(id: 1, name: "Shaders", state: .done), Stage(id: 2, name: "Install", state: .done)]
        build.done = true
        build.say("== Extract")
        build.say("romfs: 1834 files")
        build.say("== Shaders")
        build.say("translating 412 programs")

        stores.deviceStore.devices = [
            AppleDevice(id: "qa-iphone", name: "Andy’s iPhone", model: "iPhone", os: "26.0", reachable: true, transport: "usb")
        ]
        stores.deviceStore.installDevice = "qa-iphone"
        stores.deviceStore.signingTeam = "TEAM123456"
        return stores
    }

    private func leftmostBrightPixelX(in rep: NSBitmapImageRep, yRange: ClosedRange<CGFloat>? = nil) throws -> CGFloat {
        let pixels = try XCTUnwrap(DSRowAlignmentTests.pixels(rep))
        let scale = CGFloat(rep.pixelsHigh) / rep.size.height
        let minY = yRange.map { max(0, Int($0.lowerBound * scale)) } ?? 0
        let maxY = yRange.map { min(pixels.height - 1, Int($0.upperBound * scale)) } ?? (pixels.height - 1)
        let minX = max(1, Int(4 * scale))   // skip card 1pt border
        var best = pixels.width
        if minY <= maxY {
            for y in minY...maxY {
                for x in minX..<min(best, pixels.width) {
                    let i = (y * pixels.width + x) * 4
                    // Bright text pixels (title / body text), ignoring faint card background
                    if pixels.data[i] > 110 && pixels.data[i + 1] > 110 && pixels.data[i + 2] > 110 {
                        best = x
                        break
                    }
                }
            }
        }
        XCTAssertLessThan(best, pixels.width, "no bright text pixel found in yRange \(String(describing: yRange))")
        return CGFloat(best) / scale
    }

    private func renderPlain<V: View>(_ view: V, stores: LauncherStores, width: CGFloat = 680) throws -> NSBitmapImageRep {
        let wrapped = view
            .environmentObject(stores.localizer)
            .environmentObject(PadFocus())
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.black)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: wrapped)
        let size = NSSize(width: width, height: max(host.fittingSize.height, 1))
        let window = OffscreenWindow(size: size)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func accessibilityStrings(in node: NSObject) -> [String] {
        var out: [String] = []
        func visit(_ obj: NSObject) {
            for attr in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let sel = NSSelectorFromString(attr)
                if obj.responds(to: sel), let str = obj.perform(sel)?.takeUnretainedValue() as? String, !str.isEmpty {
                    out.append(str)
                }
            }
            let childrenSel = NSSelectorFromString("accessibilityChildren")
            if obj.responds(to: childrenSel), let kids = obj.perform(childrenSel)?.takeUnretainedValue() as? [NSObject] {
                kids.forEach(visit)
            }
        }
        visit(node)
        return out
    }

    func testFirstInstallDisclosureAndBodyAlignWithNeighborCardLeadingInset() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nx-align-qa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for lang in [Lang.en, .zh] {
            let stores = makeStores(lang: lang, tempDir: tempDir)
            let referenceCard = CardGroup("") {
                CardRow("0100E65002BB8000", detail: "/Volumes/Games/games") { EmptyView() }
            }
            let outcomeCollapsed = OutcomeCard(build: stores.build, devices: stores.deviceStore, onViewGame: {}, trustGuideInitiallyOpen: false)
            let outcomeExpanded = OutcomeCard(build: stores.build, devices: stores.deviceStore, onViewGame: {}, trustGuideInitiallyOpen: true)

            let refRep = try renderPlain(referenceCard, stores: stores)
            let colRep = try renderPlain(outcomeCollapsed, stores: stores)
            let expRep = try renderPlain(outcomeExpanded, stores: stores)

            let refX = try leftmostBrightPixelX(in: refRep)
            let guideCollapsedY = colRep.size.height - 52
            let colX = try leftmostBrightPixelX(in: colRep, yRange: guideCollapsedY...colRep.size.height)
            // Expanded OutcomeCard places the disclosure header and its two body steps at the bottom card.
            let expHeaderX = try leftmostBrightPixelX(in: expRep, yRange: (expRep.size.height - 180)...(expRep.size.height - 115))
            let expBodyX = try leftmostBrightPixelX(in: expRep, yRange: (expRep.size.height - 105)...expRep.size.height)

            XCTAssertEqual(refX, DS.Space.m, accuracy: 2.5, "\(lang.code) reference card inset")
            XCTAssertEqual(colX, refX, accuracy: 2.0, "\(lang.code) collapsed OutcomeCard disclosure must align with card inset")
            XCTAssertEqual(expHeaderX, refX, accuracy: 2.0, "\(lang.code) expanded OutcomeCard disclosure header must align with card inset")
            XCTAssertEqual(expBodyX, refX, accuracy: 2.0, "\(lang.code) expanded OutcomeCard disclosure body must align with disclosure header")
        }
    }

    func testDottedGroupDisclosureTitleAndBodyAlignAtRowTitleInset() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nx-dotted-align-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stores = makeStores(lang: .en, tempDir: tempDir)
        let dottedGroup = CardGroup("") {
            CardRow("Transfer mode", detail: "Connected over USB cable", dot: DS.Color.statusSuccess) { EmptyView() }
            CardDivider()
            CardDisclosure(L10n.string("flow.signingHelp", .en), isOpen: true) {}
            CardDivider()
            CardDisclosureBody {
                Text(L10n.string("dev.noTeam", .en))
                    .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        let rep = try renderPlain(dottedGroup, stores: stores)
        let titleX = try leftmostBrightPixelX(in: rep, yRange: 0...46)
        let disclosureX = try leftmostBrightPixelX(in: rep, yRange: 58...100)
        let bodyX = try leftmostBrightPixelX(in: rep, yRange: 112...rep.size.height)

        XCTAssertEqual(titleX, DSRowInset.title, accuracy: 2.5)
        XCTAssertEqual(disclosureX, titleX, accuracy: 2.0, "disclosure header in dotted group aligns past leading slot")
        XCTAssertEqual(bodyX, titleX, accuracy: 2.0, "disclosure body in dotted group aligns with disclosure header")
    }

    func testOutcomeCardShellUpdatedNoteAvoidsRepeatedDeviceNameAndExposesDisclosureA11y() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nx-ax-qa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for (lang, expectedNote, expectedCollapsed, expectedExpanded) in [
            (Lang.en, "Game shell updated", "Collapsed", "Expanded"),
            (Lang.zh, "已更新游戏壳", "已收起", "已展开"),
        ] {
            let stores = makeStores(lang: lang, tempDir: tempDir)
            func inspect(open: Bool) throws -> [String] {
                let card = OutcomeCard(build: stores.build, devices: stores.deviceStore, onViewGame: {}, trustGuideInitiallyOpen: open)
                    .environmentObject(stores.localizer)
                    .environmentObject(PadFocus())
                    .frame(width: 720)
                let host = NSHostingView(rootView: card)
                let size = NSSize(width: 720, height: max(host.fittingSize.height, 400))
                let window = OffscreenWindow(size: size)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                window.orderFront(nil)
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                return accessibilityStrings(in: window)
            }

            let collapsedTexts = try inspect(open: false)
            XCTAssertTrue(collapsedTexts.contains(expectedCollapsed), "\(lang.code) disclosure must expose collapsed state")

            let expandedTexts = try inspect(open: true)
            XCTAssertTrue(expandedTexts.contains(expectedExpanded), "\(lang.code) disclosure must expose expanded state")

            let statusText = try XCTUnwrap(expandedTexts.first { $0.contains(expectedNote) },
                                           "\(lang.code) status note must contain \(expectedNote): \(expandedTexts)")
            let deviceOccurrences = statusText.components(separatedBy: "Andy’s iPhone").count - 1
            XCTAssertEqual(deviceOccurrences, 1, "\(lang.code) status text must mention device name only once: \(statusText)")
        }
    }

    func testRenderOutcomeAndDisclosureForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else {
            throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nx-outcome-qa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lang = CaptureLanguage.current(.en)
        let stores = makeStores(lang: lang, tempDir: tempDir)

        func render<V: View>(_ name: String, width: CGFloat = 860, _ view: V) throws {
            let framed = view
                .environmentObject(stores.localizer)
                .environmentObject(PadFocus())
                .padding(DS.Space.l)
                .frame(width: width)
                .background(DS.Color.background)
                .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: framed)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = OffscreenWindow(size: host.frame.size)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
                to: output.appendingPathComponent("\(name)-\(lang.code).png")
            )
        }

        let collapsedStack = VStack(alignment: .leading, spacing: DS.Space.l) {
            OutcomeCard(build: stores.build, devices: stores.deviceStore, onViewGame: {}, trustGuideInitiallyOpen: false)
            EngineSwitcherCard(build: stores.build)
        }
        try render("outcome-collapsed", collapsedStack)

        let expandedStack = VStack(alignment: .leading, spacing: DS.Space.l) {
            OutcomeCard(build: stores.build, devices: stores.deviceStore, onViewGame: {}, trustGuideInitiallyOpen: true)
            EngineSwitcherCard(build: stores.build)
        }
        try render("outcome-expanded", expandedStack)

        let installCard = InstallCard(devices: stores.deviceStore, build: stores.build, signingHelpInitiallyOpen: true)
        try render("install-signing-help", installCard)

        let logCard = LogCard(log: stores.build.log, devices: stores.deviceStore, isOpen: .constant(true),
                              showRequests: stores.build.$done.map { _ in false }.eraseToAnyPublisher(), didShow: {})
        try render("log-open", logCard)
    }
}
