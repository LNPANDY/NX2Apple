import Foundation

// The strings of the stale-frameworks prompt (LNPANDY/NX2Apple#449). `L10n.string` asks `extra` for a key the main table does not
// hold. Localization.swift is above the size limit and may only shrink, so a new feature's strings live in their own file.
extension L10n {
    package static func extra(_ key: String, _ lang: Lang) -> String {
        guard let row = staleFrameworks[key] else { return key }
        return row[lang] ?? row[.en] ?? key
    }

    private static let staleFrameworks: [String: [Lang: String]] = [
        "stale.title": [
            .en: "Build the installed games again?",
            .zh: "要重新构建已安装的游戏吗？",
            .de: "Die installierten Spiele neu bauen?",
            .sv: "Bygga de installerade spelen igen?",
            .fr: "Reconstruire les jeux installés\u{a0}?",
            .it: "Ricompilare i giochi installati?",
        ],
        "stale.message": [
            .en: "The engine changed its shader chain. Installing a new game needs the games already in the shared app to be built again:\n\n%@\n\nContinue removes them from the shared app and deletes their local framework cache, then the build goes on. Stop the build leaves everything as it is.",
            .zh: "引擎更换了着色器链。安装新游戏需要重新构建共用应用中已有的游戏：\n\n%@\n\n选择“继续”会把它们从共用应用中移除，并删除它们的本地框架缓存，然后继续构建。选择“停止构建”则不会改动任何内容。",
            .de: "Die Engine hat ihre Shader-Kette gewechselt. Für ein neues Spiel müssen die Spiele, die schon in der gemeinsamen App sind, neu gebaut werden:\n\n%@\n\nMit „Fortfahren“ werden sie aus der gemeinsamen App entfernt und ihr lokaler Framework-Cache wird gelöscht, dann geht der Build weiter. „Build stoppen“ lässt alles, wie es ist.",
            .sv: "Motorn har bytt shaderkedja. För att installera ett nytt spel måste spelen som redan finns i den gemensamma appen byggas igen:\n\n%@\n\nFortsätt tar bort dem från den gemensamma appen och raderar deras lokala ramverkscache, sedan går bygget vidare. Stoppa bygget lämnar allt som det är.",
            .fr: "Le moteur a changé de chaîne de shaders. Installer un nouveau jeu demande de reconstruire les jeux déjà présents dans l’app partagée\u{a0}:\n\n%@\n\nContinuer les retire de l’app partagée et supprime leur cache local de frameworks, puis la construction se poursuit. Arrêter la construction ne touche à rien.",
            .it: "Il motore ha cambiato la sua catena di shader. Per installare un nuovo gioco bisogna ricompilare i giochi già presenti nell’app condivisa:\n\n%@\n\nContinua li rimuove dall’app condivisa ed elimina la loro cache locale dei framework, poi la build prosegue. Interrompi la build lascia tutto com’è.",
        ],
        "stale.removeFailed": [
            .en: "The old frameworks could not be removed: %@. Remove them from NX2Apple-shell/frameworks and build again.",
            .zh: "无法移除旧的框架：%@。请从 NX2Apple-shell/frameworks 中删除它们，然后重新构建。",
            .de: "Die alten Frameworks konnten nicht entfernt werden: %@. Entferne sie aus NX2Apple-shell/frameworks und baue erneut.",
            .sv: "De gamla ramverken kunde inte tas bort: %@. Ta bort dem från NX2Apple-shell/frameworks och bygg igen.",
            .fr: "Les anciens frameworks n’ont pas pu être supprimés\u{a0}: %@. Supprimez-les de NX2Apple-shell/frameworks et reconstruisez.",
            .it: "Impossibile rimuovere i vecchi framework: %@. Rimuovili da NX2Apple-shell/frameworks e compila di nuovo.",
        ],
        "stale.go": [
            .en: "Continue", .zh: "继续", .de: "Fortfahren", .sv: "Fortsätt", .fr: "Continuer", .it: "Continua",
        ],
        "stale.stop": [
            .en: "Stop the build", .zh: "停止构建", .de: "Build stoppen", .sv: "Stoppa bygget", .fr: "Arrêter la construction", .it: "Interrompi la build",
        ],
    ]
}
