import Foundation
import Testing
import ShellUI
@testable import ShellHost

@Suite struct GameResigningTests {
    private func fixture(_ box: FrameworkBox, folder: String = "DmGame\(Fixtures.orbit).framework") throws -> URL {
        let framework = try box.makeFramework(folder: folder)
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleExecutable": "DmGame",
            "CFBundleIdentifier": "org.test.game"
        ], format: .xml, options: 0)
        try info.write(to: framework.appendingPathComponent("Info.plist"))
        // Header selection fixture, not a loadable or signed game.
        var bytes = Data()
        for word in [UInt32(0xfeedfacf), 0x0100000c, 0, 6] {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        try bytes.write(to: framework.appendingPathComponent("DmGame"))
        return framework
    }

    @Test func failureLeavesOriginalAndRemovesStage() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let executable = framework.appendingPathComponent("DmGame")
        let original = try Data(contentsOf: executable)
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { copy in
                try Data("changed copy".utf8).write(to: copy.appendingPathComponent("DmGame"))
                throw ShellSigningError.signature("test failure")
            }
        }
        #expect(try Data(contentsOf: executable) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == [framework.lastPathComponent])
    }

    @Test func successAtomicallyReplacesOriginalAndCanRepeat() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let executable = framework.appendingPathComponent("DmGame")
        var expected = try Data(contentsOf: executable)
        for marker in [UInt8(1), 2] {
            expected.append(marker)
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { copy in
                #expect(copy != framework)
                try expected.write(to: copy.appendingPathComponent("DmGame"))
            }
            #expect(try Data(contentsOf: executable) == expected)
            #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == [framework.lastPathComponent])
        }
    }

    @Test func noncanonicalImportedFrameworkKeepsItsName() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box, folder: "OrbitImported.framework")
        #expect(GameCatalogue.readFramework(at: framework).problem == nil)
        #expect(GameResigning.isEligible(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit))
        try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { copy in
            #expect(copy.lastPathComponent == framework.lastPathComponent)
            #expect(copy != framework)
            try Data("signed copy".utf8).write(to: copy.appendingPathComponent("DmGame"))
        }
        #expect(try Data(contentsOf: framework.appendingPathComponent("DmGame")) == Data("signed copy".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == ["OrbitImported.framework"])
    }

    @Test func eligibilityDoesNotExpandOutsideImportedFrameworks() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box, folder: "OrbitImported.framework")
        #expect(!GameResigning.isEligible(framework: framework, hotRoot: box.documents, titleID: Fixtures.orbit))
        #expect(!GameResigning.isEligible(framework: framework, hotRoot: box.frameworks, titleID: "invalid"))
        #expect(!GameResigning.isEligible(framework: box.frameworks.appendingPathComponent("OrbitImported.bundle"), hotRoot: box.frameworks, titleID: Fixtures.orbit))
        let nested = box.frameworks.appendingPathComponent("nested/OrbitImported.framework")
        #expect(!GameResigning.isEligible(framework: nested, hotRoot: box.frameworks, titleID: Fixtures.orbit))
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.documents, titleID: Fixtures.orbit) { _ in
                Issue.record("Must not sign a framework outside the configured import root")
            }
        }
    }

    @Test func embeddedFrameworkAndLinksAreRejected() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.documents, titleID: Fixtures.orbit) { _ in
                Issue.record("Must not sign embedded files")
            }
        }
        try FileManager.default.createSymbolicLink(at: framework.appendingPathComponent("link"), withDestinationURL: box.root)
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { _ in
                Issue.record("Must not sign linked files")
            }
        }
    }

    @Test func changedSourceIsNotOverwrittenOrDeleted() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let movedOriginal = box.root.appendingPathComponent("original.framework")
        let marker = framework.appendingPathComponent("external-import")
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { _ in
                try FileManager.default.moveItem(at: framework, to: movedOriginal)
                try FileManager.default.copyItem(at: movedOriginal, to: framework)
                try Data("new external import".utf8).write(to: marker)
            }
        }
        #expect(try Data(contentsOf: marker) == Data("new external import".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == [framework.lastPathComponent])
    }

    @Test func sourceChangedToSymlinkIsNotExchanged() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let movedOriginal = box.root.appendingPathComponent("original.framework")
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { _ in
                try FileManager.default.moveItem(at: framework, to: movedOriginal)
                try FileManager.default.createSymbolicLink(at: framework, withDestinationURL: movedOriginal)
            }
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: framework.path) == movedOriginal.path)
        #expect(FileManager.default.fileExists(atPath: movedOriginal.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == [framework.lastPathComponent])
    }

    @MainActor @Test func cloudPromptReservesAllWindowsUntilCancelled() throws {
        let box = try Sandbox()
        let firstSettings = ShellSettingsStore(defaults: UserDefaults(suiteName: "signing-first-\(UUID().uuidString)")!)
        let secondSettings = ShellSettingsStore(defaults: UserDefaults(suiteName: "signing-second-\(UUID().uuidString)")!)
        let first = ShellHostModel(config: box.config(), shellSettings: firstSettings)
        let second = ShellHostModel(config: box.config(), shellSettings: secondSettings)
        // Isolate the session assertion from other tests' attempted launches.
        let session = GameSigningSession()
        session.register(first)
        session.register(second)
        #expect(!session.hasPendingLaunch)
        second.cloudConflict = CloudSavePrompt(gameID: Fixtures.orbit, gameTitle: "Orbit")
        #expect(session.hasPendingLaunch)
        second.cancelCloudConflict()
        #expect(!session.hasPendingLaunch)
    }


    @Test func hardLinkedSourceIsRejectedBeforeSigning() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let executable = framework.appendingPathComponent("DmGame")
        let outsideLink = box.root.appendingPathComponent("linked-image")
        try FileManager.default.linkItem(at: executable, to: outsideLink)
        let original = try Data(contentsOf: executable)
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { _ in
                Issue.record("Must not sign hard-linked source files")
            }
        }
        #expect(try Data(contentsOf: outsideLink) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path) == [framework.lastPathComponent])
    }

    @Test func interruptedStagesAreCleanedWithoutRemovingUnrelatedFolders() throws {
        let box = try FrameworkBox()
        let framework = try fixture(box)
        let stale = box.frameworks.appendingPathComponent(".resigning-" + Fixtures.orbit + "-" + UUID().uuidString)
        let unrelated = box.frameworks.appendingPathComponent(".resigning-user-files")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        #expect(throws: ShellSigningError.self) {
            try GameResigning.replace(framework: framework, hotRoot: box.frameworks, titleID: Fixtures.orbit) { _ in
                throw ShellSigningError.signature("test failure")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: box.frameworks.path)) == Set([framework.lastPathComponent, unrelated.lastPathComponent]))
    }

}
