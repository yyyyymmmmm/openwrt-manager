import Foundation
import SwiftUI
import OpenWrtKit

/// The app layer's localization entry — the String-type sibling of
/// SwiftUI's automatic LocalizedStringKey lookup.
///
/// Division of labour, following the platform's own model:
/// - SwiftUI literal call sites (Text/Label/Button/Section titles…)
///   need no code at all: the compiler turns the literal into a
///   LocalizedStringKey and the system resolves it from
///   Localizable.xcstrings in the language iOS selected for the app
///   (system language, or the per-app language in Settings). No
///   in-app language switch exists, by design.
/// - Strings produced as `String` values (status messages, activity
///   records, error text assembled in the store) cannot ride that
///   mechanism, so they resolve through `L10n` here — same catalog,
///   same language, via Bundle.
/// - The kit has no Bundle of its own; its fixed copy resolves
///   through KitL10n, which the app feeds with the very language the
///   system picked (`syncKitLanguage`), so kit-produced text (field
///   labels, error descriptions, tab titles) matches the UI around it.
enum L10n {
    /// Localized string for a catalog key (the Chinese source text).
    static func string(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    /// Localized format string with arguments — the key carries the
    /// format specifiers (%@ / %lld), matching SwiftUI's own key
    /// generation for interpolated literals.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
    }

    /// A key as a LocalizedStringKey for call sites that build keys
    /// dynamically (data-driven titles in shared components): the
    /// value is looked up when SwiftUI renders it; a miss renders the
    /// key itself, which is the right behaviour for device data.
    static func key(_ key: String) -> LocalizedStringKey {
        LocalizedStringKey(key)
    }

    /// Feed the language the system selected for this app into the
    /// kit's resolver. Called at startup and whenever the store
    /// notices the language changed (a per-app language change in
    /// Settings relaunches the app, so startup is the real path; the
    /// store call covers the in-process snapshot gate).
    static func syncKitLanguage() {
        KitL10n.appLanguage = Bundle.main.preferredLocalizations.first
    }

    /// The tag a fresh discovery's snapshot would carry if it ran
    /// now, predicted from the system language alone ("zh-cn" /
    /// "source" / nil when the router's installed catalogs decide).
    /// Used by the cache gate: a cached snapshot in a different
    /// language is re-discovered instead of rendered.
    static var expectedSnapshotLanguage: String? {
        SnapshotLanguage.expectedTag(preferredLanguages: Locale.preferredLanguages)
    }
}
