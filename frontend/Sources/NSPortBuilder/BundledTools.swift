import Foundation

/// The build tools and the Python that the release app carries in Contents/Resources (frontend/tools/bundle_tools.sh fills them in):
///
///     tools/bin   zstd, glslangValidator, spirv-cross, xcodegen
///     python/     a relocatable CPython with lz4, capstone, fontTools, zbic and nsz installed
///
/// Every function takes the resources folder as a parameter (the tests pass a fake bundle) and defaults to this app's own. There is
/// none under `swift run` or in a build that predates the bundle, and each function then answers nil, so everything else behaves as
/// it did before: Homebrew's tools, a system Python or the launcher's venv.
enum BundledTools {
    /// This app's Resources folder, but only inside a .app: `swift run` gives the executable's own folder, which is not a bundle.
    nonisolated static var resources: URL? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.resourceURL
    }

    nonisolated static func isExecutable(_ url: URL) -> Bool { FileManager.default.isExecutableFile(atPath: url.path) }

    /// tools/bin, when the bundle has it.
    nonisolated static func binDirectory(in resources: URL? = resources) -> String? {
        guard let dir = resources?.appendingPathComponent("tools/bin"),
              (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == false else { return nil }
        return dir.path
    }

    /// The path of one bundled tool (`binary` is the file name in tools/bin), when it is there and runs.
    nonisolated static func tool(_ binary: String, in resources: URL? = resources) -> String? {
        guard let url = resources?.appendingPathComponent("tools/bin/" + binary), isExecutable(url) else { return nil }
        return url.path
    }

    /// The bundled interpreter, when it is there.
    nonisolated static func python(in resources: URL? = resources) -> String? {
        guard let url = resources?.appendingPathComponent("python/bin/python3"), isExecutable(url) else { return nil }
        return url.path
    }

    /// Environment variables for a process that runs `python` (empty unless it is the bundled interpreter): no user site, so that
    /// packages in ~/Library/Python or ~/.local cannot shadow the pinned ones, and no .pyc, which would be written into the signed app.
    nonisolated static func environment(for python: String, in resources: URL? = resources) -> [String: String] {
        guard let bundled = Self.python(in: resources), bundled == python else { return [:] }
        return ["PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"]
    }

    /// A PATH for the processes that run the build: the bundled tools first, then the folder of the interpreter the build uses when it
    /// is the bundled one (so that a script that starts `python3` by name gets this one and not the system's 3.9; a bundled Python that
    /// was rejected, or a different one chosen, stays off the PATH), then `base`. `base` unchanged when there is no bundle.
    nonisolated static func path(_ base: String, python: String?, in resources: URL? = resources) -> String {
        var dirs: [String] = []
        if let bin = binDirectory(in: resources) { dirs.append(bin) }
        if let py = python, py == Self.python(in: resources) { dirs.append((py as NSString).deletingLastPathComponent) }
        return (dirs + [base]).joined(separator: ":")
    }
}
