import Foundation

/// The generic page's view model: a UCI configuration rendered as titled
/// sections of key/value rows. Used by every fallback page so discovered
/// services and settings remain fully readable without a dedicated page.
public struct GenericRow: Identifiable, Equatable, Sendable {
    public var key: String
    public var valueText: String
    /// Human label from the field catalog when one is known; nil keeps
    /// the raw option key as the display text.
    public var label: String?
    public var id: String { key }
    public var displayKey: String { label ?? key }
    public init(key: String, valueText: String, label: String? = nil) {
        self.key = key; self.valueText = valueText; self.label = label
    }
}

public struct GenericSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var title: String
    public var rows: [GenericRow]
    public init(id: String, type: String, title: String, rows: [GenericRow]) {
        self.id = id; self.type = type; self.title = title; self.rows = rows
    }
}

public enum GenericPageModel {
    public static func sections(from configuration: RouterConfiguration) -> [GenericSection] {
        configuration.sections.map { section in
            let title = section.anonymous ? section.type : "\(section.type) · \(section.id)"
            let rows = section.values.keys.sorted().map { key in
                GenericRow(key: key, valueText: displayText(section.values[key] ?? .null),
                           label: FieldCatalog.label(config: configuration.name, sectionType: section.type, option: key))
            }
            return GenericSection(id: section.id, type: section.type, title: title, rows: rows)
        }
    }

    /// Sections of one type only (e.g. just the dnsmasq section of the dhcp
    /// config for the DNS page on routers where DHCP and DNS share a file).
    public static func sections(from configuration: RouterConfiguration, type: String) -> [GenericSection] {
        sections(from: configuration).filter { $0.type == type }
    }

    public static func displayText(_ value: JSONValue) -> String {
        switch value {
        case .null: return "—"
        case .bool(let flag): return flag ? "是" : "否"
        case .number(let number):
            return number.rounded(.towardZero) == number ? String(Int64(number)) : String(number)
        case .string(let text): return text.isEmpty ? "—" : text
        case .array(let items):
            return items.isEmpty ? "—" : items.map(displayText).joined(separator: "、")
        case .object(let object):
            guard !object.isEmpty else { return "—" }
            return object.keys.sorted().map { "\($0)=\(displayText(object[$0] ?? .null))" }.joined(separator: "；")
        }
    }
}
