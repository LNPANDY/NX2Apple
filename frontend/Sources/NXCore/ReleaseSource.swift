import Foundation

/// Where the launcher learns about releases and fetches one: the second service of the self-update, next to `ProcessRunner`.
/// `AppUpdateStore` takes one through its initializer, so a test passes in a fake that answers without a network.
package protocol ReleaseSource {
    /// The body of the latest release as the GitHub API gives it. nil when there was no answer (no network, a timeout).
    func latestRelease() async -> Data?
    /// Downloads `url` to `file`. false when it did not arrive or the server did not answer 200.
    func download(_ url: URL, to file: URL) async -> Bool
}

/// The releases of a GitHub repository, over `URLSession.shared`.
package struct GitHubReleases: ReleaseSource {
    package let repository: String

    package init(repository: String = "LNPANDY/NX2Apple") { self.repository = repository }

    package func latestRelease() async -> Data? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }

    package func download(_ url: URL, to file: URL) async -> Bool {
        guard let (local, response) = try? await URLSession.shared.download(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200
        else { return false }
        return (try? FileManager.default.moveItem(at: local, to: file)) != nil
    }
}
