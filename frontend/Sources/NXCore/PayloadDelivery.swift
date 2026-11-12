import Foundation

/// A transferred code payload is distinct from an app installation and from
/// game-data readiness. The shell's receipt is the authority for activation.
package enum PayloadDelivery: Equatable {
    case awaiting, active, restartRequired

    package var textKey: String {
        switch self {
        case .awaiting: "payload.awaiting"
        case .active: "payload.active"
        case .restartRequired: "payload.restart"
        }
    }
}
