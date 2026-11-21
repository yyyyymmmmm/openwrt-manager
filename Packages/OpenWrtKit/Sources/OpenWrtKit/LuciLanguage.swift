import Foundation

/// LuCI menu titles are never translated by the router: the menu
/// endpoint returns the menu.d source strings verbatim (the pagetree is
/// even cached language-independent — verified in dispatcher.uc
/// `build_pagetree`/`menu_json` on both test routers), and the LuCI web
/// UI translates them in the browser, using the catalog served by
/// /cgi-bin/luci/admin/translations/<lang>. That endpoint keys its
/// dictionary by the SuperFastHash of the source string — the same
/// `sfh()` the web UI's cbi.js looks up with. This file mirrors that
/// exact mechanism so the app renders the same titles the web UI shows:
/// fetch the device's catalog, hash each menu title, substitute on a hit,
/// keep the source string on a miss (the web UI's own fallback).
public enum LuciHash {
    /// SuperFastHash (Paul Hsieh), byte-for-byte the algorithm of
    /// cbi.js `sfh()`: UTF-8 bytes, little-endian u16 reads, the same
    /// remainder handling and final avalanche. Verified against a live
    /// router catalog: "Firewall" -> 34f9da4c, "Network" -> e54695b9,
    /// "Processes" -> 8e770194, "Wireless" -> d55cef16.
    public static func superFastHash(_ string: String) -> String {
        let bytes = [UInt8](string.utf8)
        guard !bytes.isEmpty else { return "00000000" }
        func u16(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset])
        }
        var hash = UInt32(bytes.count)
        var remaining = bytes.count >> 2
        var offset = 0
        while remaining > 0 {
            hash = hash &+ u16(offset)
            let tmp = (u16(offset + 2) << 11) ^ hash
            hash = (hash << 16) ^ tmp
            hash = hash &+ (hash >> 11)
            offset += 4
            remaining -= 1
        }
        switch bytes.count & 3 {
        case 3:
            hash = hash &+ u16(offset)
            hash = hash ^ (hash << 16)
            hash = hash ^ (UInt32(bytes[offset + 2]) << 18)
            hash = hash &+ (hash >> 11)
        case 2:
            hash = hash &+ u16(offset)
            hash = hash ^ (hash << 11)
            hash = hash &+ (hash >> 17)
        case 1:
            hash = hash &+ UInt32(bytes[offset])
            hash = hash ^ (hash << 10)
            hash = hash &+ (hash >> 1)
        default:
            break
        }
        hash = hash ^ (hash << 3)
        hash = hash &+ (hash >> 5)
        hash = hash ^ (hash << 4)
        hash = hash &+ (hash >> 17)
        hash = hash ^ (hash << 25)
        hash = hash &+ (hash >> 6)
        return String(format: "%08x", hash)
    }

    /// cbi.js `trimws()`: the catalog lookup key is the source string
    /// with whitespace runs collapsed, so titles are normalized the
    /// same way before hashing.
    public static func lookupKey(_ string: String) -> String {
        string.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }
}

/// The translation dictionary of one LuCI language, parsed from the
/// `window.TR={...};` payload of the translations endpoint. The payload
/// is not strict JSON (the endpoint emits a trailing comma), so parsing
/// tolerates exactly that.
public struct LuciTranslationCatalog: Sendable {
    public let entries: [String: String]

    public init(entries: [String: String]) {
        self.entries = entries
    }

    public static func parse(_ payload: String) -> LuciTranslationCatalog? {
        guard let start = payload.firstIndex(of: "{"),
              let end = payload.lastIndex(of: "}") else { return nil }
        var json = String(payload[start...end])
        if json.contains(",}") { json = json.replacingOccurrences(of: ",}", with: "}") }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var entries: [String: String] = [:]
        for (key, value) in object {
            if let text = value as? String { entries[key] = text }
        }
        guard !entries.isEmpty else { return nil }
        return LuciTranslationCatalog(entries: entries)
    }

    /// The translated title, or nil when the catalog has no entry —
    /// callers keep the source string, exactly like the web UI.
    public func translate(_ title: String) -> String? {
        entries[LuciHash.superFastHash(LuciHash.lookupKey(title))]
    }
}

/// The one localization context every router-source display string goes
/// through: the negotiated catalog language plus the catalog itself.
/// Menu titles were the first consumer (round 2); sub-page labels,
/// generic-page section/field names and service titles resolve through
/// this same entry so the whole app speaks one language per discovery.
/// `language` is the canonical tag recorded in the snapshot ("zh-cn"),
/// or "source" when no catalog applies — the router's strings are
/// already in the source language (English) then.
public struct LuciLocalization: Sendable {
    public let language: String
    public let catalog: LuciTranslationCatalog?

    public init(language: String, catalog: LuciTranslationCatalog?) {
        self.language = language
        self.catalog = catalog
    }

    /// No catalog: every string stays as the router served it.
    public static let source = LuciLocalization(language: "source", catalog: nil)

    /// The display form of a router-source string: the catalog's
    /// translation when it has one, the source string otherwise — the
    /// LuCI web UI's own fallback rule.
    public func translate(_ text: String) -> String {
        catalog?.translate(text) ?? text
    }
}

/// Predicts, from the client's preferences alone, the catalog language
/// a fresh discovery will aim for. Used to notice that a cached
/// snapshot was discovered under a different language than the one the
/// user would get now (system language changed, or the snapshot predates
/// language tagging). A heuristic trigger only: nil means "cannot
/// predict" (languages whose catalog tag is not a simple function of
/// the preference), and callers must not loop on a mismatch — the
/// router's registered languages have the final say during discovery.
public enum SnapshotLanguage {
    public static func expectedTag(preferredLanguages: [String]) -> String? {
        guard let first = preferredLanguages.first?.lowercased() else { return nil }
        if first.hasPrefix("zh") { return first.contains("hant") ? "zh-tw" : "zh-cn" }
        if first.hasPrefix("en") { return "source" }
        return nil
    }
}

/// Picks the catalog language a router will actually serve. The order
/// is the app's localization policy (systematic localization package):
///   1. The client's preferred languages, in order — the app follows
///      the system language. The first preference that is English
///      settles it (source strings, no catalog); the first preference
///      the router has a registered language for wins its catalog.
///   2. The router's own fixed luci.main.lang, when step 1 matched
///      nothing (e.g. the system language is not installed on the
///      router at all).
///   3. nil — source strings.
/// Returns the dash form the translations endpoint expects ("zh-cn"),
/// or nil when the effective language is English / undetermined —
/// English needs no catalog, its titles are the source strings already.
/// (Before this package, a fixed luci.main.lang outranked the client's
/// languages; the user-mandated order is system-first, and the
/// round-2 negotiation test was updated to match.)
public enum LuciLanguageNegotiator {
    public static func effectiveLanguage(luciConfig: JSONValue?, preferredLanguages: [String]) -> String? {
        guard let values = luciConfig?["values"].objectValue else { return nil }
        var mainLang: String?
        var available: Set<String> = []
        // Sections are matched by their uci section ID: the types are
        // not what the names suggest (verified live — "main" has type
        // "core", "languages" has type "internal").
        for (sectionID, section) in values {
            if sectionID == "main" {
                mainLang = section["lang"].stringValue ?? section["lang"].textValue
            } else if sectionID == "languages" {
                for key in (section.objectValue ?? [:]).keys where !key.hasPrefix(".") {
                    available.insert(key.lowercased())
                }
            }
        }
        // Step 1: the client's languages, in preference order.
        for tag in preferredLanguages {
            let parts = tag.replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").map { $0.lowercased() }
            guard let base = parts.first else { continue }
            if base == "en" { return nil }
            var candidates: [String] = []
            if parts.count >= 3 { candidates.append("\(base)_\(parts[parts.count - 1])") }
            if parts.count >= 2 { candidates.append("\(base)_\(parts[1])") }
            // Script-default region (CLDR): a Chinese preference is a
            // script plus an optional region, but LuCI registers one
            // catalog per script family — zh_cn for Simplified, zh_tw
            // for Traditional. "zh-Hans" (no region) and "zh-Hans-US"
            // (a region the router has no catalog for) name the zh_cn
            // catalog just as surely as "zh-Hans-CN" does. (Build #8
            // field failure: with only the exact forms above, an
            // auto-lang router stayed English for these tag shapes
            // while a fixed-lang router masked it via step 2 — verified
            // against both routers' real uci responses.)
            if base == "zh", parts.count >= 2 {
                if parts[1] == "hans" { candidates.append("zh_cn") }
                if parts[1] == "hant" { candidates.append("zh_tw") }
            }
            // Any registered variant of the same base language, in
            // stable order: the last resort before abandoning this
            // preference (covers a bare "zh", or the one Chinese
            // catalog a router ships when it is not the script default).
            candidates.append(contentsOf: available.filter { $0.hasPrefix("\(base)_") }.sorted())
            candidates.append(base)
            for candidate in candidates where available.contains(candidate) {
                return candidate.replacingOccurrences(of: "_", with: "-")
            }
        }
        // Step 2: the router's fixed configured language.
        let configured = (mainLang ?? "auto").lowercased()
        if configured != "auto" {
            return configured == "en" ? nil : configured.replacingOccurrences(of: "_", with: "-")
        }
        return nil
    }
}
