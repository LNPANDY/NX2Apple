import Foundation

/// The build tools and the Python that the release app carries in Contents/Resources (frontend/tools/bundle_tools.sh fills them in):
///
///     tools/bin   zstd, glslangValidator, spirv-cross, xcodegen
///     python/     a relocatable CPython with lz4, capstone, fontTools and nsz installed
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

    /// A PATH for the processes that run the build: the bundled tools first, then the bundled Python's folder (so that a script that
    /// starts `python3` by name gets this one and not the system's 3.9), then `base`. `base` unchanged when there is no bundle.
    nonisolated static func path(_ base: String, in resources: URL? = resources) -> String {
        var dirs: [String] = []
        if let bin = binDirectory(in: resources) { dirs.append(bin) }
        if let py = python(in: resources) { dirs.append((py as NSString).deletingLastPathComponent) }
        return (dirs + [base]).joined(separator: ":")
    }
}
