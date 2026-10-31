import CoreText
import SwiftUI
import XCTest
@testable import NSPortBuilder

/// The buttons and dropdowns in the setting rows share one width and one height (LauncherControl) and show their label on one
/// line. Nothing here lists labels: the real Settings and Builds pages are drawn in every language the launcher has, and each
/// control reports what it measured (LauncherControlSample), so a new button, a new string or a new language is checked as soon as
/// a page shows it.
final class LauncherControlWidthTests: XCTestCase {
    private func width(_ text: String, size: CGFloat = 13) throws -> CGFloat {
        let font = try XCTUnwrap(Typography.manropeFont(size: size, weight: .semibold))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    // MARK: Languages

    func testThePickerOffersEveryLanguage() {
        let offered = Set(BuilderView.languageCodes.filter { !$0.isEmpty })
        XCTAssertEqual(offered, Set(Lang.allCases.map(\.rawValue)), "Settings > Language lists the launcher's languages")
    }

    func testDropdownChoicesFitBesideTheChevron() throws {
        for code in BuilderView.languageCodes {
            let key = "settings.language." + (code.isEmpty ? "system" : code)
            XCTAssertNotNil(L10n.table[key], key)
            for lang in Lang.allCases {
                let text = L10n.string(key, lang)
                XCTAssertLessThanOrEqual(try width(text), LauncherControl.choiceWidth, "\(lang) \(key): \(text)")
            }
        }
    }

    /// The library's Owned/Built switch is one LauncherControl wide, so each label fits its half in bold, without shrinking.
    func testLibraryFilterLabelsFitTheirSegment() throws {
        let room = (LauncherControl.width - 2 * 3 - 2) / 2 - 2 * 12
        for filter in LibraryFilter.allCases {
            for lang in Lang.allCases {
                let text = L10n.string(filter.labelKey, lang)
                let font = try XCTUnwrap(Typography.manropeFont(size: 12.5, weight: .bold))
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                XCTAssertLessThanOrEqual(CTLineGetTypographicBounds(line, nil, nil, nil), room, "\(lang) \(filter.labelKey): \(text)")
            }
        }
    }

    // MARK: Real pages

    private final class Samples { var all: [LauncherControlSample] = [] }

    private struct Scenario {
        let name: String
        let page: LauncherPage
        /// The controls this state must show at least, so that a page that draws nothing cannot pass.
        let atLeast: Int
        let set: (BuildModel, GameLibrary, URL) throws -> Void
    }

    private func makeRepo(_ directory: URL, git: Bool) throws -> String {
        let repo = directory.appendingPathComponent(git ? "clone" : "zip")
        let program = repo.appendingPathComponent("dm/tools/nx_extract/Program.cs")
        try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: program)
        if git { try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true) }
        return repo.path
    }

    private var scenarios: [Scenario] {
        let device = AppleDevice(id: "00008150-AAAA", name: "iPhone", model: "iPhone 17 Pro Max", os: "27.0", reachable: true)
        // The names of devices and teams are the user's own, so the scenarios use short ones: only the launcher's words are measured.
        let team = SigningTeam(id: "E75GJAP35S", identity: "Apple Development: Mia (ABCDE12345)")
        let release = AppUpdate.Release(tag: "v9.9.9", url: "https://example.org/app.zip", digest: nil)
        func missing(_ id: String, action: String = "", command: [String] = []) -> BuildModel.Dep {
            BuildModel.Dep(id: id, name: "dep.xcode", hint: "dep.xcode.hint", present: false, actionLabel: action, installCmd: command)
        }
        return [
            Scenario(name: "settings without a repository", page: .settings, atLeast: 4) { m, _, _ in
                m.repoPath = ""
                m.appInstallability = .ok
            },
            Scenario(name: "settings with a ZIP copy and a library folder", page: .settings, atLeast: 6) { m, library, directory in
                m.repoPath = try self.makeRepo(directory, git: false)
                m.appInstallability = .ok
                m.depsChecked = true
                m.deps = [BuildModel.Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: true, installCmd: [])]
                library.setFolder(directory)
            },
            Scenario(name: "settings with a clone that is behind and an app update", page: .settings, atLeast: 6) { m, _, directory in
                m.repoPath = try self.makeRepo(directory, git: true)
                m.repoBehind = 2
                m.appInstallability = .ok
                m.appUpdate = release
            },
            Scenario(name: "settings with an update ready to restart into", page: .settings, atLeast: 4) { m, _, directory in
                m.repoPath = try self.makeRepo(directory, git: true)
                m.appInstallability = .ok
                m.appStaged = AppUpdate.Staged(release: release, app: directory.appendingPathComponent("NX2Apple.app"))
            },
            Scenario(name: "settings with every kind of missing tool", page: .settings, atLeast: 6) { m, _, directory in
                m.repoPath = try self.makeRepo(directory, git: true)
                m.depsChecked = true
                m.deps = [missing("a"), missing("b", command: ["brew", "install", "x"]), missing("c", action: "dep.xcode.fix", command: ["x"])]
                m.depsExpanded = true
            },
            Scenario(name: "builds without a repository", page: .builds, atLeast: 4) { m, _, _ in
                m.repoPath = ""
                m.target = "mac-app"
            },
            Scenario(name: "builds with files chosen for a Mac app", page: .builds, atLeast: 5) { m, _, directory in
                m.repoPath = try self.makeRepo(directory, git: true)
                m.target = "mac-app"
                m.gameDir = directory.path
                m.outDir = directory.path
                m.slots[0].paths = [directory.appendingPathComponent("Hades [0100535012974000].nsp").path]
                m.slots[1].paths = [directory.appendingPathComponent("Hades update [0100535012974800].nsp").path]
            },
            Scenario(name: "builds for an iPhone with a device and a team", page: .builds, atLeast: 6) { m, _, directory in
                m.repoPath = try self.makeRepo(directory, git: true)
                m.target = "ios"
                m.devicesChecked = true
                m.devices = [device]
                m.teams = [team]
                m.installDevice = device.id
                m.signingTeam = team.id
            },
            Scenario(name: "a finished Mac app build", page: .builds, atLeast: 6) { m, _, directory in
                m.repoPath = try self.makeRepo(directory, git: true)
                m.target = "mac-app"
                m.done = true
                m.macAppPath = directory.appendingPathComponent("Hades.app").path
            },
            Scenario(name: "a build installed on an iPhone", page: .builds, atLeast: 6) { m, _, directory in
                m.repoPath = try self.makeRepo(directory, git: true)
                m.target = "ios"
                m.done = true
                m.devicesChecked = true
                m.devices = [device]
                m.installedOn = device.id
                m.archivePath = directory.appendingPathComponent("romfs").path
            },
            Scenario(name: "a finished iPhone build without an install", page: .builds, atLeast: 6) { m, _, directory in
                m.repoPath = try self.makeRepo(directory, git: true)
                m.target = "ios"
                m.done = true
                m.devicesChecked = true
                m.ipaPath = directory.appendingPathComponent("Hades.ipa").path
                m.archivePath = directory.appendingPathComponent("romfs").path
            },
        ]
    }

    @MainActor private func measure(_ scenario: Scenario, _ lang: Lang) throws -> [LauncherControlSample] {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("control-width-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = BuildModel()
        let library = GameLibrary(file: directory.appendingPathComponent("library.json"))
        try scenario.set(model, library, directory)
        model.lang = lang
        let samples = Samples()
        let view = ContentView(model: model, library: library, initialPage: scenario.page, activeBuildID: nil, performStartupChecks: false,
                               search: nil, olderTools: [], manageOpen: false, padRing: false)
            .environment(\.measuresLauncherControls, true)
            .onPreferenceChange(LauncherControlSamples.self) { samples.all = $0 }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 2600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        return samples.all
    }

    /// Settings and Builds, in every language: each button and dropdown of a row is LauncherControl.width wide and
    /// LauncherControl.height high, and its label fits on one line.
    @MainActor func testEveryRowControlOnTheRealPagesFitsInEveryLanguage() throws {
        let keys = ["repoPath", "depsExpanded", "buildTarget", "installDevice", "signingTeam", "buildOutputDirectory", "autoUpdateRepo"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        for scenario in scenarios {
            for lang in Lang.allCases {
                let samples = try measure(scenario, lang)
                let at = "\(lang), \(scenario.name)"
                XCTAssertGreaterThanOrEqual(samples.count, scenario.atLeast, "\(at): the page showed fewer controls than expected")
                for (index, sample) in samples.enumerated() {
                    XCTAssertEqual(sample.size.width, LauncherControl.width, "\(at), control \(index)")
                    XCTAssertEqual(sample.size.height, LauncherControl.height, "\(at), control \(index)")
                    XCTAssertLessThanOrEqual(sample.labelWidth, sample.room,
                                             "\(at), control \(index): its label needs \(sample.labelWidth) pt on one line, the control has \(sample.room)")
                }
            }
        }
    }

    // MARK: The style itself

    private let tooLong = "A label far longer than any button in a setting row could hold on one line"

    @MainActor private func samples<V: View>(of view: V) throws -> [LauncherControlSample] {
        let samples = Samples()
        let host = NSHostingView(rootView: view.launcherRowControls().environment(\.measuresLauncherControls, true)
            .onPreferenceChange(LauncherControlSamples.self) { samples.all = $0 }.frame(width: 400, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        return samples.all
    }

    /// The probe reports a label that does not fit, so the page test above can fail.
    @MainActor func testTheProbeSeesALabelThatDoesNotFit() throws {
        let found = try samples(of: Button(tooLong) {}.buttonStyle(LauncherSecondaryButtonStyle()))
        XCTAssertEqual(found.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(found.first).labelWidth, LauncherControl.buttonLabelWidth)
    }

    /// Whatever the label, a button, a dropdown and the cream capsule are one size, so none can be taller than its neighbours.
    @MainActor func testAControlNeverGrowsWithItsLabel() throws {
        let controls: [(String, AnyView)] = [
            ("button", AnyView(Button(tooLong) {}.buttonStyle(LauncherSecondaryButtonStyle()))),
            ("short button", AnyView(Button("OK") {}.buttonStyle(LauncherSecondaryButtonStyle()))),
            ("dropdown", AnyView(LauncherDropdown(options: [("a", tooLong)], selection: "a", style: .button) { _ in })),
            ("cream button", AnyView(Text(tooLong).font(.manrope(13, .semibold)).launcherRowControlFrame()
                .background(LauncherPalette.cream, in: Capsule()))),
        ]
        for (name, control) in controls {
            let found = try samples(of: control)
            let size = try XCTUnwrap(found.first, name).size
            XCTAssertEqual(size.width, LauncherControl.width, name)
            XCTAssertEqual(size.height, LauncherControl.height, name)
        }
    }

    // MARK: Launch options

    /// Every slider's value has one width, so the sliders are equally long: the widest value, four digits by four in pixels or
    /// three in percent, fits it on one line.
    @MainActor func testTheWidestSliderValueFitsItsColumn() {
        for value in ["8888×8888", "888%"] {
            let width = NSHostingView(rootView: Text(value).font(.manrope(13, .semibold)).monospacedDigit().fixedSize()).fittingSize.width
            XCTAssertLessThanOrEqual(width, LaunchControl.valueWidth, value)
        }
    }

    /// The Launch options sheet at its own size, with a choice made so that Reset to tested defaults shows: in every language
    /// the button is one LauncherControl and its label fits on one line.
    @MainActor func testLaunchOptionsResetFitsInEveryLanguage() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launch-width-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let titleID = "0100FFFF28200000"
        let app = directory.appendingPathComponent("Game.app")
        let dm = app.appendingPathComponent("Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        let info: [String: Any] = ["DMTitleID": titleID, "CFBundleIdentifier": "org.example.launchwidth." + titleID.lowercased()]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let scale = #"{"env": "DM_RENDER_SCALE", "kind": "range", "label": "Render scale", "note": "", "default": "1.0", "section": "Game", "min": 0.5, "max": 1.0, "step": 0.05}"#
        try #"{"game": "\#(titleID)", "settings": [\#(scale)]}"#.write(to: dm.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)
        var game = LibraryGame(titleID: titleID, name: "Game")
        game.appPath = app.path
        game.launchOptions["DM_FULLSCREEN"] = "1"   // Display mode is the launcher's own row: the choice stays in the library
        struct Snapshot: Codable { let games: [LibraryGame]; let folder: String }
        let file = directory.appendingPathComponent("library.json")
        try JSONEncoder().encode(Snapshot(games: [game], folder: directory.path)).write(to: file)
        let library = GameLibrary(file: file)
        let model = BuildModel()
        for lang in Lang.allCases {
            model.lang = lang
            let samples = Samples()
            let view = LaunchOptionsView(m: model, library: library, gameID: game.id).environmentObject(PadFocus())
                .environment(\.measuresLauncherControls, true)
                .onPreferenceChange(LauncherControlSamples.self) { samples.all = $0 }
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            window.orderOut(nil)
            XCTAssertFalse(samples.all.isEmpty, "\(lang): the sheet showed no Reset to tested defaults")
            for sample in samples.all {
                XCTAssertEqual(sample.size.width, LauncherControl.width, "\(lang)")
                XCTAssertEqual(sample.size.height, LauncherControl.height, "\(lang)")
                XCTAssertLessThanOrEqual(sample.labelWidth, sample.room, "\(lang): \(L10n.string("launch.reset", lang))")
            }
        }
    }
}
