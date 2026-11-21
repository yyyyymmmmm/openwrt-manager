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

/// Picks the catalog language a router will actually serve, mirroring
/// dispatcher.uc `determine_request_language`: a fixed luci.main.lang
/// wins; "auto" negotiates the client's preferred languages against the
/// languages registered in the luci config. Returns the dash form the
/// translations endpoint expects ("zh-cn"), or nil when the effective
/// language is English / undetermined — English needs no catalog, its
/// titles are the source strings already.
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
        let configured = (mainLang ?? "auto").lowercased()
        if configured != "auto" {
            return configured == "en" ? nil : configured.replacingOccurrences(of: "_", with: "-")
        }
        for tag in preferredLanguages {
            let parts = tag.replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").map { $0.lowercased() }
            guard let base = parts.first else { continue }
            var candidates: [String] = []
            if parts.count >= 3 { candidates.append("\(base)_\(parts[parts.count - 1])") }
            if parts.count >= 2 { candidates.append("\(base)_\(parts[1])") }
            candidates.append(base)
            for candidate in candidates where available.contains(candidate) {
                return candidate.replacingOccurrences(of: "_", with: "-")
            }
        }
        return nil
    }
}
