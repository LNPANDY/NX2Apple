import XCTest
@testable import NXCore

/// #1017: a Mac build with only the Command Line Tools selected is accepted when those tools really build for the Mac, and never for an
/// iPhone build. The answer comes from the tools, not from what is installed.
final class MacToolCapabilityTests: XCTestCase {
    private func runner(selected: String, iosSDK: Bool) -> FakeProcessRunner {
        let r = FakeProcessRunner()
        r.answer = { launch in
            if launch.executable.hasSuffix("xcode-select") { return ProcessResult(out: selected + "\n") }
            if launch.arguments.contains("iphoneos") { return ProcessResult(status: iosSDK ? 0 : 1) }
            return ProcessResult()
        }
        return r
    }

    func testAMacBuildWithToolsThatRunNeedsNoFullXcode() {
        let tools = "/Library/Developer/CommandLineTools"
        guard FileManager.default.fileExists(atPath: tools) else { return }   // the selected folder must exist for the state to be read
        let dep = DependencyCheck.xcodeDep(needsIOS: false, customApp: nil, runner: runner(selected: tools, iosSDK: false), macToolchainRuns: true)
        XCTAssertTrue(dep.present)
    }

    func testAnIPhoneBuildStillNeedsTheSelectedXcodeAndItsIOSPlatform() {
        let tools = "/Library/Developer/CommandLineTools"
        guard FileManager.default.fileExists(atPath: tools) else { return }
        let dep = DependencyCheck.xcodeDep(needsIOS: true, customApp: nil, runner: runner(selected: tools, iosSDK: false), macToolchainRuns: true)
        XCTAssertFalse(dep.present)
    }

    func testToolsThatDoNotRunTheMacCompilerAreNotAccepted() {
        let tools = "/Library/Developer/CommandLineTools"
        guard FileManager.default.fileExists(atPath: tools), Toolchain.installedXcode() != nil else { return }   // the CLT-only state needs an unselected Xcode
        let dep = DependencyCheck.xcodeDep(needsIOS: false, customApp: nil, runner: runner(selected: tools, iosSDK: false), macToolchainRuns: false)
        XCTAssertFalse(dep.present)
    }
}
