import Foundation

/// Fixed copy produced inside the kit: tab and page titles, field
/// labels, status words, and the error/warning text that reaches the
/// user through the app. The kit's source language is zh-Hans — every
/// call site writes the Chinese source string — and this resolver is
/// the single place that turns it into the app's language.
///
/// The app shell reports its effective language once at launch
/// (Bundle.main.preferredLocalizations, which is how iOS itself
/// resolves the system language against the localizations the app
/// ships). Unset — unit tests, command-line use — resolves to the
/// source language, so kit behavior without an app shell is unchanged.
/// Router-source strings do NOT come through here; they belong to the
/// router and resolve through LuciLocalization instead.
public enum KitL10n {
    /// BCP-47 tag of the app's effective language ("zh-Hans", "en", …),
    /// set by the app shell at launch. Kit code only reads it.
    public static var appLanguage: String?

    public static var isEnglish: Bool {
        guard let appLanguage else { return false }
        return appLanguage.lowercased().hasPrefix("en")
    }

    /// The display form of a fixed kit string: the English rendering
    /// when the app runs in English and the table has one, the Chinese
    /// source string otherwise.
    public static func text(_ zhSource: String) -> String {
        isEnglish ? (englishTable[zhSource] ?? zhSource) : zhSource
    }

    /// Format variant: the source string is the format template
    /// (printf placeholders), translated as a whole before arguments
    /// are substituted.
    public static func format(_ zhFormat: String, _ arguments: CVarArg...) -> String {
        String(format: text(zhFormat), arguments: arguments)
    }
}
