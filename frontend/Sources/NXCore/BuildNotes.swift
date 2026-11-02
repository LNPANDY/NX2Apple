import Foundation

/// LNPANDY/NX2Apple#320: build-script notes the launcher shows as popups. The Qt window matches the same text (`nspb_qt/build_notes.py`).
package enum BuildNotes {
    /// Printed by build_ipa_from_nsp.py before it rebuilds the shader libraries (with the `shaders_stale` event), then its reason.
    package static let staleShaders = "[NOTE] cached shader libraries cannot be reused"
    /// The reason the popup's text describes: a new shader translator.
    package static let chainReason = "the translation chain changed"

    /// Whether text holds the note for a changed shader translator.
    package static func chainChanged(_ text: String) -> Bool {
        text.contains(staleShaders) && text.contains(chainReason)
    }
}
