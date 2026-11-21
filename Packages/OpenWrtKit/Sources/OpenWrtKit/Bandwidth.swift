import Foundation

// MARK: - Bandwidth report (package I, audit U2)
//
// `nlbw -c json` dumps the nlbwmon database as rows carrying every
// tracked dimension at once (family, host, MAC, layer-7 protocol,
// connection count, rx/tx bytes and packets), so one device appears
// in many rows. The bandwidth page needs the per-host rollup: who
// used how much, in plain totals. This parser aggregates the dump
// into that rollup; the raw dump stays available to the page as the
// demoted raw layer.

/// One host's aggregated traffic over the accounting period.
public struct BandwidthHost: Identifiable, Equatable, Sendable {
    /// Aggregation key: the normalized MAC when the row carried a
    /// usable one, otherwise the host address itself.
    public var id: String
    public var mac: String?
    public var address: String?
    public var downloadBytes: Int64
    public var uploadBytes: Int64
    public var connections: Int

    public var totalBytes: Int64 { downloadBytes + uploadBytes }

    public init(id: String, mac: String? = nil, address: String? = nil,
                downloadBytes: Int64 = 0, uploadBytes: Int64 = 0, connections: Int = 0) {
        self.id = id; self.mac = mac; self.address = address
        self.downloadBytes = downloadBytes; self.uploadBytes = uploadBytes
        self.connections = connections
    }
}

/// The whole report: hosts sorted by total traffic, descending,
/// plus the period totals the summary line quotes.
public struct BandwidthReport: Equatable, Sendable {
    public var hosts: [BandwidthHost]
    public var totalDownload: Int64
    public var totalUpload: Int64

    public var totalBytes: Int64 { totalDownload + totalUpload }

    public init(hosts: [BandwidthHost], totalDownload: Int64, totalUpload: Int64) {
        self.hosts = hosts; self.totalDownload = totalDownload; self.totalUpload = totalUpload
    }

    /// This host's share of the period total, 0...1; nil when the
    /// period total is zero (a share of nothing is not a number).
    public func share(of host: BandwidthHost) -> Double? {
        guard totalBytes > 0 else { return nil }
        return Double(host.totalBytes) / Double(totalBytes)
    }
}

public enum BandwidthParser {
    /// Parse `nlbw -c json` output into the per-host rollup. Returns
    /// nil when the text is not a recognizable nlbw dump at all (the
    /// page then keeps the raw text and says so, instead of inventing
    /// an empty report). Row shapes accepted:
    /// - the canonical dump: {"data": [[fam, host, mac, layer7,
    ///   conns, rx_bytes, rx_pkts, tx_bytes, tx_pkts], ...]}, with an
    ///   optional "columns" array naming the fields, which wins over
    ///   positions whenever present;
    /// - a bare top-level array of such rows;
    /// - rows as objects keyed by field name (mac/ip/host/rx_bytes/
    ///   tx_bytes/conns and their common aliases).
    /// Within an array row without column names, fields are found by
    /// shape — the MAC-shaped string, the address-shaped string —
    /// and the numeric fields keep the client's invariant order
    /// (conns, rx_bytes, rx_pkts, tx_bytes, tx_pkts), as printed by
    /// `nlbw -c show`/`csv` alike.
    public static func parse(_ text: String) -> BandwidthReport? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        let rows: [JSONValue]
        var columns: [String] = []
        if let object = root.objectValue {
            guard let dataRows = object["data"]?.arrayValue else { return nil }
            rows = dataRows
            columns = (object["columns"]?.arrayValue ?? []).compactMap { $0.stringValue }
        } else if let array = root.arrayValue {
            rows = array
        } else {
            return nil
        }

        var byKey: [String: BandwidthHost] = [:]
        var order: [String] = []
        for row in rows {
            guard let fields = fields(of: row, columns: columns) else { continue }
            let mac = fields.mac.flatMap { $0.uppercased() }
            let usableMAC = mac.flatMap { $0 == "00:00:00:00:00:00" ? nil : $0 }
            guard let key = usableMAC ?? fields.address else { continue }
            if byKey[key] == nil {
                byKey[key] = BandwidthHost(id: key, mac: usableMAC, address: fields.address)
                order.append(key)
            }
            byKey[key]?.downloadBytes += fields.download
            byKey[key]?.uploadBytes += fields.upload
            byKey[key]?.connections += fields.connections
            // A MAC-keyed host may appear under several addresses
            // (dual-stack, re-leased); keep the first IPv4 seen as
            // the display address.
            if let address = fields.address, let existing = byKey[key]?.address,
               existing.contains(":"), !address.contains(":") {
                byKey[key]?.address = address
            }
        }
        guard !byKey.isEmpty else { return nil }
        let hosts = order.compactMap { byKey[$0] }
            .sorted { $0.totalBytes > $1.totalBytes }
        return BandwidthReport(hosts: hosts,
                               totalDownload: hosts.reduce(0) { $0 + $1.downloadBytes },
                               totalUpload: hosts.reduce(0) { $0 + $1.uploadBytes })
    }

    // MARK: Row field extraction

    private struct RowFields {
        var mac: String?
        var address: String?
        var download: Int64
        var upload: Int64
        var connections: Int
    }

    private static func fields(of row: JSONValue, columns: [String]) -> RowFields? {
        if let object = row.objectValue {
            let mac = firstString(object, ["mac"])
            let address = firstString(object, ["ip", "host", "address"])
            guard mac != nil || address != nil,
                  let download = firstInt(object, ["rx_bytes", "rx", "download", "down"]),
                  let upload = firstInt(object, ["tx_bytes", "tx", "upload", "up"]) else { return nil }
            return RowFields(mac: mac, address: address, download: download, upload: upload,
                             connections: firstInt(object, ["conns", "connections", "conn"]).map(Int.init) ?? 0)
        }
        guard let items = row.arrayValue else { return nil }
        if !columns.isEmpty, columns.count == items.count {
            var named: [String: JSONValue] = [:]
            for (index, name) in columns.enumerated() { named[name.lowercased()] = items[index] }
            let mac = firstString(named, ["mac"])
            let address = firstString(named, ["ip", "host", "address"])
            guard mac != nil || address != nil,
                  let download = firstInt(named, ["rx_bytes", "rx", "download", "down"]),
                  let upload = firstInt(named, ["tx_bytes", "tx", "upload", "up"]) else { return nil }
            return RowFields(mac: mac, address: address, download: download, upload: upload,
                             connections: firstInt(named, ["conns", "connections", "conn"]).map(Int.init) ?? 0)
        }
        // Shape-based: strings identify themselves, numbers keep the
        // client's invariant order.
        var mac: String?
        var address: String?
        var numbers: [Int64] = []
        for item in items {
            if let string = item.stringValue {
                if mac == nil, isMACShape(string) { mac = string; continue }
                if address == nil, isAddressShape(string) { address = string; continue }
                if let number = Int64(string) { numbers.append(number) }
            } else if let number = item.intValue {
                numbers.append(Int64(number))
            }
        }
        guard mac != nil || address != nil, numbers.count >= 4 else { return nil }
        // conns, rx_bytes, rx_pkts, tx_bytes, tx_pkts — with only the
        // byte pair present (4 numbers would be rx, rx_pkts, tx,
        // tx_pkts after a missing conns in no known layout; the
        // canonical layouts always carry conns, so 5 is the norm and
        // anything shorter is read as conns-less pairs from index 0).
        if numbers.count >= 5 {
            return RowFields(mac: mac, address: address,
                             download: numbers[1], upload: numbers[3],
                             connections: Int(numbers[0]))
        }
        return RowFields(mac: mac, address: address,
                         download: numbers[0], upload: numbers[2], connections: 0)
    }

    private static func firstString(_ object: [String: JSONValue], _ keys: [String]) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    private static func firstInt(_ object: [String: JSONValue], _ keys: [String]) -> Int64? {
        for key in keys {
            if let value = object[key]?.intValue { return Int64(value) }
            if let string = object[key]?.stringValue, let value = Int64(string) { return value }
        }
        return nil
    }

    private static func isMACShape(_ string: String) -> Bool {
        let parts = string.split(separator: ":")
        guard parts.count == 6 else { return false }
        return parts.allSatisfy { part in
            part.count == 2 && part.allSatisfy { $0.isHexDigit }
        }
    }

    private static func isAddressShape(_ string: String) -> Bool {
        // IPv4: four dotted decimal groups.
        let v4 = string.split(separator: ".")
        if v4.count == 4, v4.allSatisfy({ Int($0) != nil }) { return true }
        // IPv6: contains a colon but is not the MAC (already claimed).
        return string.contains(":") && string.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
    }
}
