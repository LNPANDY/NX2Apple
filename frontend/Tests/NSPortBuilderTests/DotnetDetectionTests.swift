import XCTest
import SwiftUI
@testable import NSPortBuilder

/// The .NET row checks the dotnet the build runs, in the build's own order, and wants an SDK 10 from it.
final class DotnetDetectionTests: XCTestCase {
    func testTheBuildsOrder() {
        // build_ipa_from_nsp.py's TOOL_PATHS: Homebrew, /usr/local/bin, the installer's folder, then ~/.dotnet
        XCTAssertEqual(BuildModel.dotnetCandidates(home: "/Users/p"),
                       ["/opt/homebrew/bin/dotnet", "/usr/local/bin/dotnet", "/usr/local/share/dotnet/dotnet", "/Users/p/.dotnet/dotnet"])
    }

    func testOnlyAnSDK10Counts() {
        XCTAssertFalse(BuildModel.hasSDK10("7.0.402 [/usr/local/share/dotnet/sdk]\n"))   // an Intel .NET 7 in front of ~/.dotnet
        XCTAssertFalse(BuildModel.hasSDK10(""))
        XCTAssertFalse(BuildModel.hasSDK10("8.0.318 [/x/sdk]\n9.0.100 [/x/sdk]"))
        XCTAssertTrue(BuildModel.hasSDK10("7.0.402 [/a/sdk]\n10.0.403 [/b/sdk]\n"))
        XCTAssertTrue(BuildModel.hasSDK10("11.0.100-preview.1 [/b/sdk]"))
    }

    func testFixLinksOnlyWhenAnotherDotnetComesFirst() {
        let plain = BuildModel.dotnetInstallCommand(first: nil, home: "/Users/p").last!
        XCTAssertTrue(plain.contains("--install-dir $HOME/.dotnet"))
        XCTAssertFalse(plain.contains("ln -sf"))
        let own = BuildModel.dotnetInstallCommand(first: "/Users/p/.dotnet/dotnet", home: "/Users/p").last!
        XCTAssertFalse(own.contains("ln -sf"))
        let shadowed = BuildModel.dotnetInstallCommand(first: "/usr/local/share/dotnet/dotnet", home: "/Users/p").last!
        XCTAssertTrue(shadowed.hasSuffix("ln -sf \"$HOME/.dotnet/dotnet\" /usr/local/bin/dotnet"))
        // a link in /usr/local/bin cannot get ahead of Homebrew's own
        XCTAssertFalse(BuildModel.dotnetInstallCommand(first: "/opt/homebrew/bin/dotnet", home: "/Users/p").last!.contains("ln -sf"))
    }

    func testTheRow() {
        let shadowed = BuildModel.dotnetDep(first: "/usr/local/share/dotnet/dotnet", ok: false, usable: "/Users/p/.dotnet/dotnet", home: "/Users/p")
        XCTAssertFalse(shadowed.present)
        XCTAssertEqual(shadowed.detail, "dep.dotnet.shadowed:/usr/local/share/dotnet/dotnet:/Users/p/.dotnet/dotnet")
        XCTAssertEqual(shadowed.actionLabel, "dep.xcode.fix")
        XCTAssertTrue(shadowed.installCmd.last!.contains("ln -sf"))

        let ready = BuildModel.dotnetDep(first: "/usr/local/bin/dotnet", ok: true, usable: nil, home: "/Users/p")
        XCTAssertTrue(ready.present)
        XCTAssertEqual(ready.detail, "/usr/local/bin/dotnet")

        let none = BuildModel.dotnetDep(first: nil, ok: false, usable: nil, home: "/Users/p")
        XCTAssertEqual(none.detail, "dep.dotnet.missing")
        XCTAssertEqual(none.actionLabel, "")
        XCTAssertFalse(none.installCmd.last!.contains("ln -sf"))

        // an old SDK in front and none anywhere else: Install brings .NET 10 into ~/.dotnet and puts it in front
        let old = BuildModel.dotnetDep(first: "/usr/local/share/dotnet/dotnet", ok: false, usable: nil, home: "/Users/p")
        XCTAssertEqual(old.detail, "dep.dotnet.missing")
        XCTAssertEqual(old.actionLabel, "")
        XCTAssertTrue(old.installCmd.last!.contains("ln -sf"))
    }

    @MainActor func testTheShadowedRowNamesBothPaths() {
        let model = BuildModel()
        model.lang = .en
        XCTAssertEqual(model.depDetail(BuildModel.dotnetDep(first: "/usr/local/share/dotnet/dotnet", ok: false, usable: "/opt/x/dotnet")),
                       "the build runs /usr/local/share/dotnet/dotnet, which has no SDK 10. Fix puts /opt/x/dotnet in front of it")
    }

    /// Opt-in native rendering for pull request screenshots (NX_LAUNCHER_CAPTURE_DIR): Settings with the .NET row of a Mac whose
    /// /usr/local/share/dotnet holds an older .NET in front of the .NET 10 in ~/.dotnet, and the same row once Fix has run.
    @MainActor func testRenderTheDotnetRowForVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["NX_LAUNCHER_CAPTURE_DIR"] else { throw XCTSkip("Set NX_LAUNCHER_CAPTURE_DIR to capture native views") }
        let output = URL(fileURLWithPath: directory)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("dotnet-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let oldRepo = UserDefaults.standard.object(forKey: "repoPath"), oldExpanded = UserDefaults.standard.object(forKey: "depsExpanded")
        defer {
            UserDefaults.standard.set(oldRepo, forKey: "repoPath")
            UserDefaults.standard.set(oldExpanded, forKey: "depsExpanded")
        }
        let model = BuildModel()
        model.repoPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        model.lang = CaptureLanguage.current(.en)
        model.depsChecked = true
        model.depsExpanded = true
        let rows = [BuildModel.Dep(id: "xcode", name: "dep.xcode", hint: "dep.xcode.hint", present: true, installCmd: []),
                    BuildModel.Dep(id: "metal", name: "dep.metal", hint: "dep.metal.hint", present: true, installCmd: [])]
        let python = BuildModel.Dep(id: "python", name: "dep.python", hint: "dep.python.hint", present: true, detail: "dep.bundled", installCmd: [])
        let library = GameLibrary(file: temporary.appendingPathComponent("library.json"))
        for (name, dotnet) in [("dotnet-shadowed", BuildModel.dotnetDep(first: "/usr/local/share/dotnet/dotnet", ok: false, usable: NSHomeDirectory() + "/.dotnet/dotnet")),
                               ("dotnet-fixed", BuildModel.dotnetDep(first: "/usr/local/bin/dotnet", ok: true, usable: nil))] {
            model.deps = rows + [dotnet, python]
            let host = NSHostingView(rootView: ContentView(model: model, library: library, initialPage: .settings, performStartupChecks: false))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1400), styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("\(name)-\(model.lang.rawValue).png"))
            window.orderOut(nil)
        }
    }
}
