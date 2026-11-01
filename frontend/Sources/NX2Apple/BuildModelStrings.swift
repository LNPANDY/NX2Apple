import NXCore
import NXModel

// The language and the strings of `BuildModel` are the `Localizer`'s (LNPANDY/NX2Apple#387). `BuildModel` is not observed for them:
// a language change reaches the views through the environment. These two forward to it for the text the model writes itself.
extension BuildModel {
    var lang: Lang { get { localizer.lang } set { localizer.lang = newValue } }
    func t(_ key: String) -> String { localizer.t(key) }
}
