import Foundation
import NXCore

// The experimental builder (#749): Settings' switch and the nxb binary it uses, and what the build gets from them.
// The rules (where nxb comes from, the variables) are ExperimentalBuilder in NXCore.

extension BuildStore {
    /// The `nxb` the next build takes, nil when there is none (the switch is then only a note in the log).
    package var experimentalBuilderBinary: String? {
        ExperimentalBuilder.resolve(customPath: experimentalBuilderPath, bundled: bundledBuilder)
    }

    /// The variables the build gets for the experimental builder, empty when it is off or no nxb is found. Says in the log which it is.
    package func builderEnvironment() -> [String: String] {
        guard experimentalBuilder else { return [:] }
        guard let nxb = experimentalBuilderBinary else {
            say(t("msg.builderMissing"))
            return [:]
        }
        say(String(format: t("msg.builderOn"), nxb))
        return ExperimentalBuilder.environment(nxb: nxb)
    }
}
