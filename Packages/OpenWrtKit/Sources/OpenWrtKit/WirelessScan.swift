import Foundation

// MARK: - Wireless neighbourhood scan (package I, audit U4)
//
// The channel page promised analysis but only ever showed the
// router's own radios. The missing half is the neighbourhood: what
// other networks are on the air, on which channels, how strong.
// iwinfo's scan call returns exactly that per radio; this is its
// model and parser. A scan is best-effort by nature (a busy radio
// may refuse, the object may not be granted) — the client treats it
// that way and the page says so when the list comes back empty.

public struct WirelessScanEntry: Identifiable, Equatable, Sendable {
    /// Radio netdev the scan ran on.
    public var device: String
    /// Network name; nil for hidden networks (empty SSID on the air).
    public var ssid: String?
    public var bssid: String
    public var channel: Int?
    public var signal: Int?
    /// Whether the network advertises encryption; nil when the scan
    /// result did not say.
    public var encrypted: Bool?

    public var id: String { "\(device)|\(bssid)" }

    public init(device: String, ssid: String? = nil, bssid: String,
                channel: Int? = nil, signal: Int? = nil, encrypted: Bool? = nil) {
        self.device = device; self.ssid = ssid; self.bssid = bssid
        self.channel = channel; self.signal = signal; self.encrypted = encrypted
    }
}

public enum WirelessScanParser {
    /// ubus iwinfo scan: {"results": [{"ssid": "...", "bssid": "AA:…",
    /// "channel": 6, "signal": -55, "quality": 70,
    /// "encryption": {"enabled": true, ...}}]}.
    public static func results(_ value: JSONValue, device: String) -> [WirelessScanEntry] {
        (value["results"].arrayValue ?? []).compactMap { item in
            guard let bssid = item["bssid"].stringValue, !bssid.isEmpty else { return nil }
            let ssid = item["ssid"].stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let encryption = item["encryption"]
            let encrypted = encryption["enabled"].boolValue
                ?? encryption.objectValue.map { !$0.isEmpty }
            return WirelessScanEntry(
                device: device,
                ssid: ssid,
                bssid: bssid.uppercased(),
                channel: item["channel"].intValue,
                signal: item["signal"].intValue,
                encrypted: encrypted)
        }
    }

    /// How many scanned networks sit on each channel — the raw
    /// material for the congestion grade and the per-channel counts
    /// the channel page shows.
    public static func channelCounts(_ entries: [WirelessScanEntry]) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for entry in entries {
            guard let channel = entry.channel else { continue }
            counts[channel, default: 0] += 1
        }
        return counts
    }
}
