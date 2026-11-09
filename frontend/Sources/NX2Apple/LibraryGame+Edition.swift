import Foundation

/// #1057. The library keeps showing the Switch game it has a profile for. When files of the game's inputs say they are the
/// Switch 2 Edition upgrade, the hero adds one line saying that content was found and is not supported. Nothing is ever labelled
/// as the Switch 2 Edition because of it: the build is the Switch game.
extension LibraryGame {
    /// An input file (base, update, DLC, a game folder) whose name says "Switch 2 Edition". Only the names of files the player added are
    /// read, never a guess from a title ID.
    var switch2EditionContentFound: Bool { Self.names(in: inputs.values.flatMap { $0 }).contains(where: Self.saysSwitch2Edition) }

    static func saysSwitch2Edition(_ name: String) -> Bool {
        name.range(of: "switch[ _.-]*2[ _.-]*edition", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func names(in paths: [String]) -> [String] { paths.map { ($0 as NSString).lastPathComponent } }
}
