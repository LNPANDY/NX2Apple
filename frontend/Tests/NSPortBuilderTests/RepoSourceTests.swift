import XCTest
@testable import NSPortBuilder

/// Which source the repository is downloaded from (RepoSource.swift). The probes are injected, so
/// nothing here touches the network: `pick` is the decision, `answers` is the process in the app.
final class RepoSourceTests: XCTestCase {
    private func names(_ sources: [RepoSource]) -> [String] { sources.map(\.name) }

    func testGitHubComesFirstWhenNothingIsRemembered() {
        XCTAssertEqual(RepoEndpoints.all.first, RepoEndpoints.github)
        XCTAssertEqual(names(RepoEndpoints.ordered(preferred: nil)), names(RepoEndpoints.all))
        XCTAssertEqual(names(RepoEndpoints.ordered(preferred: "nonsense")), names(RepoEndpoints.all))
    }

    func testTheRememberedSourceIsTriedFirstAndTheRestFollow() {
        let last = RepoEndpoints.all.last!
        let ordered = RepoEndpoints.ordered(preferred: last.id)
        XCTAssertEqual(ordered.first, last)
        XCTAssertEqual(ordered.count, RepoEndpoints.all.count)
        XCTAssertEqual(Set(ordered.map(\.id)), Set(RepoEndpoints.all.map(\.id)), "no source is dropped or duplicated")
    }

    func testTheFirstSourceThatAnswersWins() {
        let dead: Set<String> = [RepoEndpoints.github.id]        // the network cannot reach GitHub
        let picked = RepoEndpoints.pick(preferred: nil) { !dead.contains($0.id) }
        XCTAssertNotEqual(picked?.id, RepoEndpoints.github.id)
        XCTAssertNotNil(picked, "a fallback is used rather than failing")
    }

    func testNothingAnsweringIsNil() {
        XCTAssertNil(RepoEndpoints.pick(preferred: nil) { _ in false })
    }

    /// A remembered source is preferred, but a silent one still falls through to GitHub.
    func testARememberedSourceThatStopsAnsweringFallsBackToTheRest() {
        guard let last = RepoEndpoints.all.last else { return XCTFail("no sources") }
        let picked = RepoEndpoints.pick(preferred: last.id) { $0.id == RepoEndpoints.github.id }
        XCTAssertEqual(picked, RepoEndpoints.github)
    }

    func testEverySourceIsACloneURLAndKeepsItsHost() {
        for s in RepoEndpoints.all {
            XCTAssertTrue(s.url.hasSuffix(".git"), s.url)
            XCTAssertFalse(s.host.isEmpty, s.url)
            XCTAssertFalse(s.name.isEmpty, s.id)
        }
        XCTAssertEqual(RepoEndpoints.github.host, "github.com")
    }
}
