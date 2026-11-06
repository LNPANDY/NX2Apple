import Foundation

/// The host's input_map.h names and ordered parser. Names are case-insensitive and keys have exclusive ownership.
package enum ControllerMap {
    package static let buttons = ["A", "B", "X", "Y", "LS", "RS", "L", "R", "ZL", "ZR", "Plus", "Minus", "Left", "Up", "Right", "Down"]
    package static let functions = buttons + ["LUp", "LDown", "LLeft", "LRight", "RUp", "RDown", "RLeft", "RRight", "Shake"]
    package static let defaultKeys: [String: Int] = ["A":38,"B":40,"X":32,"Y":34,"LS":3,"RS":5,"L":12,"R":14,"ZL":6,"ZR":8,"Plus":36,"Minus":48,"Left":123,"Up":126,"Right":124,"Down":125,"LUp":13,"LDown":1,"LLeft":0,"LRight":2,"Shake":49]
    static func entries(_ value: String, pad: Bool) -> [(String, String)]? {
        guard !value.isEmpty, value.utf8.count <= 1023 else { return nil }
        var parts = value.split(separator: ",", omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() } // host permits one trailing comma
        var result: [(String, String)] = []
        for part in parts {
            let pair = part.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, let name = (pad ? buttons : functions).first(where: { $0.lowercased() == pair[0].lowercased() }) else { return nil }
            let target = String(pair[1])
            if target.lowercased() == "none" { result.append((name, "none")); continue }
            if pad {
                guard let to = (buttons + ["Shake"]).first(where: { $0.lowercased() == target.lowercased() }) else { return nil }
                result.append((name, to))
            } else {
                guard !target.isEmpty, target.utf8.count < 8, target.utf8.allSatisfy({ (48...57).contains($0) }), let code = Int(target), code < 128 else { return nil }
                result.append((name, String(code)))
            }
        }
        return result
    }
    package static func valid(_ value: String, pad: Bool) -> Bool { entries(value, pad: pad) != nil }
    /// Complete effective keys. A missing function has no key.
    package static func keys(_ value: String?) -> [String: Int] {
        var keys = defaultKeys
        guard let value, let entries = entries(value, pad: false) else { return keys }
        for (name, target) in entries {
            keys[name] = nil
            if let code = Int(target) {
                keys = keys.filter { $0.value != code }
                keys[name] = code
            }
        }
        return keys
    }
    package static func pad(_ value: String?) -> [String: String] {
        guard let value, let entries = entries(value, pad: true) else { return [:] }
        var result: [String: String] = [:]
        for (name, target) in entries { result[name] = target == name ? nil : target }
        return result
    }

    /// Match launcher.c precedence without writing preferences when an env.txt disables saved choices.
    package static func savingEnabled(environment: [String: String], playerEnv: String?, appEnv: String?) -> Bool {
        if let value = environment["DM_SAVED_CHOICES"] { return value != "0" }
        for text in [playerEnv, appEnv].compactMap({ $0 }) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.hasPrefix("#"), let eq = s.firstIndex(of: "=") else { continue }
                let key = s[..<eq].trimmingCharacters(in: .whitespaces)
                if key == "DM_SAVED_CHOICES" { return s[s.index(after: eq)...] != "0" }
            }
        }
        return true
    }
}
