import SwiftUI
import OpenWrtKit

struct RouterRecordsView: View {
    @Environment(RouterStore.self) private var store
    let kind: RouterRecordKind
    @State private var records: [JSONValue] = []
    @State private var loading = false
    @State private var error: String?
    @State private var updatedAt: Date?
    @State private var query = ""
    private var filtered: [String] { records.map(Self.formatted).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            Section {
                ReadStatus(updatedAt: updatedAt, error: error, retry: { Task { await load() } }, loading: loading)
            }
            Section(updatedAt == nil ? "路由器记录" : "\(filtered.count) 条记录") {
                ForEach(Array(filtered.enumerated()), id: \.offset) { _, text in Text(text).font(AppTypography.secondary).textSelection(.enabled) }
            }
        }.appDetailStyle(kind.title).searchable(text: $query, prompt: "筛选记录")
            .task(id: store.connectionID) { await load() }.refreshable { await load() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("刷新", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) } }
    }
    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let generation = store.connectionID
        do {
            let value = try await store.records(kind)
            guard generation == store.connectionID, !Task.isCancelled else { return }
            records = value; error = nil; updatedAt = Date()
        } catch {
            guard generation == store.connectionID, !Task.isCancelled else { return }
            error = FriendlyError.message(error)
        }
    }
    private static func formatted(_ record: JSONValue) -> String {
        if let text = record.stringValue { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(record), let text = String(data: data, encoding: .utf8) else { return "无法显示此记录" }
        return text
    }
}
