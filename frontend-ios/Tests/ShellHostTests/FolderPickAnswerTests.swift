import Foundation
import Testing
@testable import ShellHost

@Suite struct FolderPickAnswerTests {
    @Test func theFirstAnswerWinsAndLaterOnesAreIgnored() {
        var seen: [URL?] = []
        let answer = FolderPickAnswer<URL> { seen.append($0) }
        let url = URL(fileURLWithPath: "/tmp/games")
        answer.finish(url)
        answer.finish(nil)   // the dismissal that follows a pick
        answer.finish(URL(fileURLWithPath: "/tmp/other"))
        #expect(seen == [url])
        #expect(answer.answered)
    }

    @Test func aDismissalWithoutAPickAnswersNilOnce() {
        var calls = 0
        var last: URL? = URL(fileURLWithPath: "/x")
        let answer = FolderPickAnswer<URL> { calls += 1; last = $0 }
        answer.finish(nil)
        answer.finish(nil)
        #expect(calls == 1)
        #expect(last == nil)
    }
}
