import Foundation
import NXCore

extension BuildStore {
    /// Resolves the Python interpreter for `nxnative` or `S2Arm` builds while rejecting stale cross-upstream caches
    /// and any interpreter under MacNativeGames's `uv-python` directory.
    package func resolveBuildPython(includeS2Arm: Bool = false) -> String {
        let expected: EngineUpstreamKind = includeS2Arm ? .s2arm : .nxnative
        let cached = deps.pythonPath
        let upstreamMatches = deps.pythonUpstream == nil || deps.pythonUpstream == expected
        let isManagedMNG = MacNativeGamesBuilder.isManagedUVPython(cached, home: home)
            || MacNativeGamesBuilder.isManagedUVPython(cached)
        if deps.checked, !cached.isEmpty, upstreamMatches, !isManagedMNG {
            return cached
        }
        return Toolchain.findPython(includeS2Arm: includeS2Arm).path
    }

    /// The environment the build's tools run in, for the script: PATH, the user, the .NET runtime root, the bundled Python's settings.
    func toolEnvironment(python py: String) -> [String: String] {
        // The root of the runtime the apphost looks for: derived from the detected installation, not assumed to be ~/.dotnet (Homebrew keeps it in .../opt/dotnet/libexec).
        // Only set when the derivation actually answered. TMPDIR as well: .NET 10 on macOS keeps the named mutex its first-run configure takes under $TMPDIR/.dotnet/shm.
        var denv: [String: String] = ["PATH": BuildCommands.toolPath("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", python: py),
                                      "USER": NSUserName(), "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
                                      "TMPDIR": NSTemporaryDirectory()]
        if let droot = Toolchain.dotnetRoot(for: deps.dotnetPath.isEmpty ? "dotnet" : deps.dotnetPath) {
            denv["DOTNET_ROOT"] = droot   // both variables carry the same root, as the apphost checks the arch-specific one first
            denv["DOTNET_ROOT_ARM64"] = droot
        }
        // The bundled Python lives inside the signed app: a .pyc written there would change what the signature seals
        // (the packages are compiled at bundle time), and a user site must not shadow its pinned packages.
        denv.merge(BundledTools.environment(for: py)) { $1 }
        return ProxyEnvironment.merged(into: denv)
    }
}
