import SwiftUI
import NXCore
import NXModel

/// The question before a build with a game engine file (BuildStore+GameEngine.swift): its first use, or a file that does not match the
/// base game's update or the engine. Build goes on with it, Cancel leaves everything as it is.
private struct GameEnginePrompt: ViewModifier {
    @ObservedObject var m: BuildStore
    @EnvironmentObject var loc: Localizer

    func body(content: Content) -> some View {
        content.alert(loc.t("engineFile.title"), isPresented: Binding(get: { m.gameEngineQuestion != nil },
                                                                     set: { if !$0 { m.declineGameEngine() } })) {
            Button(loc.t("engineFile.go")) { m.acceptGameEngine() }
            Button(loc.t("engineFile.cancel"), role: .cancel) { m.declineGameEngine() }
        } message: {
            Text(m.gameEngineQuestion.map(m.gameEngineMessage) ?? "")
        }
    }
}

extension View {
    package func gameEnginePrompt(_ m: BuildStore) -> some View { modifier(GameEnginePrompt(m: m)) }
}
