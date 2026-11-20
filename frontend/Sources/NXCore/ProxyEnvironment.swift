import CFNetwork
import Foundation

/// Standard proxy environment propagation and macOS system proxy bridging.
/// Reads only explicit environment variables and Apple's `CFNetworkCopySystemProxySettings()`.
package enum ProxyEnvironment {
    private static let keyPairs: [(lower: String, upper: String)] = [
        ("http_proxy", "HTTP_PROXY"),
        ("https_proxy", "HTTPS_PROXY"),
        ("all_proxy", "ALL_PROXY"),
        ("no_proxy", "NO_PROXY"),
    ]

    private static let activeProxyKeys: Set<String> = [
        "http_proxy", "HTTP_PROXY",
        "https_proxy", "HTTPS_PROXY",
        "all_proxy", "ALL_PROXY",
    ]

    /// Returns macOS system proxy settings via `CFNetworkCopySystemProxySettings()`.
    package static func currentSystemProxySettings() -> [String: Any]? {
        CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
    }

    /// Merges explicit proxy variables from `processEnv` (pairing lower/upper case keys),
    /// falling back to macOS system proxy settings when no proxy variable is present.
    package static func merged(
        into env: [String: String],
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        systemSettings: [String: Any]? = nil
    ) -> [String: String] {
        var result = env
        var hasExplicitProxy = false

        for pair in keyPairs {
            let envVal = nonEmpty(result[pair.lower]) ?? nonEmpty(result[pair.upper])
            let procVal = nonEmpty(processEnv[pair.lower]) ?? nonEmpty(processEnv[pair.upper])
            if let value = envVal ?? procVal {
                result[pair.lower] = value
                result[pair.upper] = value
                if activeProxyKeys.contains(pair.lower) {
                    hasExplicitProxy = true
                }
            }
        }

        if !hasExplicitProxy,
           let settings = systemSettings ?? currentSystemProxySettings() {
            var appliedAny = false
            if intFlag(settings[kCFNetworkProxiesHTTPEnable as String]) == 1,
               let host = nonEmpty(settings[kCFNetworkProxiesHTTPProxy as String] as? String),
               let port = positivePort(settings[kCFNetworkProxiesHTTPPort as String]) {
                let url = "http://\(host):\(port)"
                result["http_proxy"] = url
                result["HTTP_PROXY"] = url
                appliedAny = true
            }
            if intFlag(settings[kCFNetworkProxiesHTTPSEnable as String]) == 1,
               let host = nonEmpty(settings[kCFNetworkProxiesHTTPSProxy as String] as? String),
               let port = positivePort(settings[kCFNetworkProxiesHTTPSPort as String]) {
                let url = "http://\(host):\(port)"
                result["https_proxy"] = url
                result["HTTPS_PROXY"] = url
                appliedAny = true
            }
            if !appliedAny,
               intFlag(settings[kCFNetworkProxiesSOCKSEnable as String]) == 1,
               let host = nonEmpty(settings[kCFNetworkProxiesSOCKSProxy as String] as? String),
               let port = positivePort(settings[kCFNetworkProxiesSOCKSPort as String]) {
                let url = "socks5h://\(host):\(port)"
                result["all_proxy"] = url
                result["ALL_PROXY"] = url
                appliedAny = true
            }
            if appliedAny,
               result["no_proxy"] == nil,
               let exceptions = settings[kCFNetworkProxiesExceptionsList as String] as? [String] {
                let cleaned = exceptions.compactMap(nonEmpty)
                if !cleaned.isEmpty {
                    let joined = cleaned.joined(separator: ",")
                    result["no_proxy"] = joined
                    result["NO_PROXY"] = joined
                }
            }
        }

        // Prevent curl 18 / HTTP/2 sideband disconnects when git fetches through local proxies.
        if activeProxyKeys.contains(where: { nonEmpty(result[$0]) != nil }),
           nonEmpty(result["GIT_CONFIG_COUNT"]) == nil,
           nonEmpty(processEnv["GIT_CONFIG_COUNT"]) == nil {
            result["GIT_CONFIG_COUNT"] = "2"
            result["GIT_CONFIG_KEY_0"] = "http.version"
            result["GIT_CONFIG_VALUE_0"] = "HTTP/1.1"
            result["GIT_CONFIG_KEY_1"] = "http.postBuffer"
            result["GIT_CONFIG_VALUE_1"] = "524288000"
        }
        return result
    }

    /// Builds a `URLSessionConfiguration.connectionProxyDictionary` when explicit HTTP/HTTPS
    /// proxy environment variables are present on `processEnv`. Returns `nil` otherwise so
    /// `URLSession` uses macOS system proxy settings natively.
    package static func urlSessionProxyDictionary(
        processEnv: [String: String] = ProcessInfo.processInfo.environment
    ) -> [AnyHashable: Any]? {
        let rawHTTPS = nonEmpty(processEnv["https_proxy"]) ?? nonEmpty(processEnv["HTTPS_PROXY"])
        let rawHTTP = nonEmpty(processEnv["http_proxy"]) ?? nonEmpty(processEnv["HTTP_PROXY"])
        let rawAll = nonEmpty(processEnv["all_proxy"]) ?? nonEmpty(processEnv["ALL_PROXY"])

        var dict: [AnyHashable: Any] = [:]
        if let rawHTTP, let parsed = parseProxyEndpoint(rawHTTP) {
            if parsed.isSocks {
                dict[kCFNetworkProxiesSOCKSEnable as String] = 1
                dict[kCFNetworkProxiesSOCKSProxy as String] = parsed.host
                dict[kCFNetworkProxiesSOCKSPort as String] = parsed.port
            } else {
                dict[kCFNetworkProxiesHTTPEnable as String] = 1
                dict[kCFNetworkProxiesHTTPProxy as String] = parsed.host
                dict[kCFNetworkProxiesHTTPPort as String] = parsed.port
            }
        }
        if let rawHTTPS, let parsed = parseProxyEndpoint(rawHTTPS) {
            if parsed.isSocks {
                dict[kCFNetworkProxiesSOCKSEnable as String] = 1
                dict[kCFNetworkProxiesSOCKSProxy as String] = parsed.host
                dict[kCFNetworkProxiesSOCKSPort as String] = parsed.port
            } else {
                dict[kCFNetworkProxiesHTTPSEnable as String] = 1
                dict[kCFNetworkProxiesHTTPSProxy as String] = parsed.host
                dict[kCFNetworkProxiesHTTPSPort as String] = parsed.port
            }
        }
        if dict.isEmpty, let rawAll, let parsed = parseProxyEndpoint(rawAll) {
            if parsed.isSocks {
                dict[kCFNetworkProxiesSOCKSEnable as String] = 1
                dict[kCFNetworkProxiesSOCKSProxy as String] = parsed.host
                dict[kCFNetworkProxiesSOCKSPort as String] = parsed.port
            } else {
                dict[kCFNetworkProxiesHTTPEnable as String] = 1
                dict[kCFNetworkProxiesHTTPProxy as String] = parsed.host
                dict[kCFNetworkProxiesHTTPPort as String] = parsed.port
                dict[kCFNetworkProxiesHTTPSEnable as String] = 1
                dict[kCFNetworkProxiesHTTPSProxy as String] = parsed.host
                dict[kCFNetworkProxiesHTTPSPort as String] = parsed.port
            }
        }
        return dict.isEmpty ? nil : dict
    }

    private static func parseProxyEndpoint(_ raw: String) -> (host: String, port: Int, isSocks: Bool)? {
        let normalized = raw.contains("://") ? raw : "http://" + raw
        guard let comps = URLComponents(string: normalized),
              let host = nonEmpty(comps.host),
              let port = comps.port, port > 0 && port <= 65535 else {
            return nil
        }
        let scheme = (comps.scheme ?? "http").lowercased()
        let isSocks = scheme.hasPrefix("socks")
        return (host, port, isSocks)
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func intFlag(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        if let b = value as? Bool { return b ? 1 : 0 }
        return 0
    }

    private static func positivePort(_ value: Any?) -> Int? {
        let port: Int
        if let n = value as? NSNumber { port = n.intValue }
        else if let i = value as? Int { port = i }
        else if let s = value as? String, let parsed = Int(s) { port = parsed }
        else { return nil }
        return (port > 0 && port <= 65535) ? port : nil
    }
}
