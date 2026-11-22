import Foundation

/// Python packages the launcher installs for a build (today: nsz), kept in a folder the launcher owns.
///
/// Homebrew's Python and the system Python are externally managed (PEP 668): `pip install nsz` stops with
/// `externally-managed-environment` (LNPANDY/NX2Apple#1500). So pip installs with `--target` into
/// `~/Library/Application Support/NX2Apple/python-packages/<major.minor>`, and every process that imports nsz gets that folder
/// on PYTHONPATH. Nothing is installed into the interpreter, and `--break-system-packages` is never used.
package enum PythonPackages {
    /// The folder for one Python version, such as `3.14`. Packages built for one minor version are not shared with another.
    package static func directory(version: String, home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/NX2Apple/python-packages/" + version
    }

    /// "3.14" for the interpreter, "unknown" when it cannot be run.
    package static func versionName(python: String, runner: ProcessRunner = SystemProcessRunner()) -> String {
        guard let v = Toolchain.pythonVersion(python, runner: runner) else { return "unknown" }
        return "\(v.0).\(v.1)"
    }

    /// `env` with the launcher's package folder for this interpreter in front of PYTHONPATH.
    package static func environment(python: String, env: [String: String], home: String = NSHomeDirectory(),
                                    runner: ProcessRunner = SystemProcessRunner()) -> [String: String] {
        let dir = directory(version: versionName(python: python, runner: runner), home: home)
        var out = env
        if let old = env["PYTHONPATH"], !old.isEmpty { out["PYTHONPATH"] = dir + ":" + old } else { out["PYTHONPATH"] = dir }
        return out
    }

    /// The command of the install: `python -m pip install --target <folder> nsz`.
    package static func nszInstallCommand(python: String, directory: String) -> [String] {
        [python, "-m", "pip", "install", "--target", directory, "nsz"]
    }

    /// Install nsz into the launcher's folder. `env` is the one from `environment(python:env:)`, so its PYTHONPATH names the folder.
    package static func installNsz(python: String, env: [String: String], home: String = NSHomeDirectory(),
                                   runner: ProcessRunner = SystemProcessRunner(), line: @escaping @Sendable (String) -> Void) -> Bool {
        let dir = directory(version: versionName(python: python, runner: runner), home: home)
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
            line("Cannot create \(dir): \(error.localizedDescription)")
            return false
        }
        return runner.runCaptured(nszInstallCommand(python: python, directory: dir), env: env, line: line)
    }
}
