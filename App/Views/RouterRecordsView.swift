import SwiftUI
import OpenWrtKit

struct RouterLogDirectoryView: View {
    var body: some View {
        List {
            Section("日志来源") {
                NavigationLink("系统日志") { RouterRecordsView(kind: .logs) }.accessibilityIdentifier("router-system-log")
                NavigationLink("内核日志") { RouterRecordsView(kind: .kernelLogs) }.accessibilityIdentifier("router-kernel-log")
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("系统日志")
    }
}

struct RouterRecordsView: View {
    @Environment(RouterStore.self) private var store
    let kind: RouterRecordKind
    @State private var records: [JSONValue] = []
    @State private var loading = false
    @State private var error: String?
    @State private var updatedAt: Date?
    @State private var query = ""
    @State private var severity = -1
    @State private var facility = -1
    @State private var reverse = false
    @State private var invertText = false
    @State private var requestID = UUID()
    private var isLog: Bool { kind == .logs || kind == .kernelLogs }
    private static let severities = ["紧急", "警报", "严重", "错误", "警告", "通知", "信息", "调试"]
    private static let facilities = ["内核", "用户", "邮件", "守护进程", "认证", "Syslog", "打印", "新闻", "UUCP", "Cron", "私有认证", "FTP", "NTP", "审计", "控制台", "定时任务", "Local 0", "Local 1", "Local 2", "Local 3", "Local 4", "Local 5", "Local 6", "Local 7"]
    private var filtered: [String] {
        var previousKernelPriority: Int?
        let matches = records.compactMap { record -> String? in
            let text = Self.formatted(record)
            var priority = record["priority"].intValue
            if kind == .kernelLogs, let raw = record.stringValue, raw.hasPrefix("<"), let end = raw.firstIndex(of: ">") {
                let tag = String(raw[raw.index(after: raw.startIndex)..<end])
                priority = tag == "c" ? previousKernelPriority : Int(tag)
                if let priority { previousKernelPriority = priority }
            }
            if severity >= 0, !(priority.map { $0 >= 0 && $0 % 8 <= severity } ?? false) { return nil }
            if facility >= 0, !(priority.map { $0 >= 0 && $0 / 8 == facility } ?? false) { return nil }
            if !query.isEmpty, text.localizedCaseInsensitiveContains(query) == invertText { return nil }
            return text
        }
        return reverse ? Array(matches.reversed()) : matches
    }
    var body: some View {
        List {
            Section {
                ReadStatus(updatedAt: updatedAt, error: error, retry: { Task { await load() } }, loading: loading)
            }
            if isLog {
                Section {
                    Picker("最低严重程度", selection: $severity) {
                        Text("全部（包含未返回级别）").tag(-1)
                        ForEach(0..<8, id: \.self) { Text(Self.severities[$0] + "及更严重").tag($0) }
                    }
                    if kind == .logs {
                        Picker("日志类别", selection: $facility) {
                            Text("全部（包含未返回类别）").tag(-1)
                            ForEach(0..<Self.facilities.count, id: \.self) { Text(Self.facilities[$0]).tag($0) }
                        }
                    }
                    Toggle("排除匹配文字", isOn: $invertText)
                    Toggle("倒序显示", isOn: $reverse)
                } header: { Text("筛选与排序") } footer: {
                    Text(kind == .logs ? "读取最近 200 条，日期按手机时区显示。筛选作用于已读取数据；具体级别或类别筛选不包含缺少相应信息的记录。" : "读取当前内核环形日志；方括号时间为开机后的秒数。级别筛选按 dmesg 原始优先级处理。")
                }
            }
            Section(updatedAt == nil ? "路由器记录" : "\(filtered.count) 条记录") {
                if updatedAt != nil && filtered.isEmpty { Text(error == nil ? "没有匹配的记录。" : "当前读取失败，上次数据没有匹配项。").foregroundStyle(AppPalette.muted) }
                ForEach(Array(filtered.enumerated()), id: \.offset) { _, text in Text(text).font(AppTypography.secondary).textSelection(.enabled) }
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle(kind.title).searchable(text: $query, prompt: "筛选记录")
            .task(id: store.connectionID) { records = []; updatedAt = nil; await load() }.refreshable { await load() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("刷新", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) } }
    }
    private func load() async {
        let request = UUID()
        requestID = request
        loading = true
        defer { if requestID == request { loading = false } }
        let generation = store.connectionID
        do {
            let value = try await store.records(kind)
            guard generation == store.connectionID, requestID == request, !Task.isCancelled else { return }
            records = value; error = nil; updatedAt = Date()
        } catch {
            guard generation == store.connectionID, requestID == request, !Task.isCancelled else { return }
            self.error = FriendlyError.message(error)
        }
    }
    private static func formatted(_ record: JSONValue) -> String {
        if let text = record.stringValue { return text }
        if let message = record["msg"].stringValue {
            var metadata: [String] = []
            if let milliseconds = record["time"].doubleValue, milliseconds.isFinite,
               abs(milliseconds) < 8_640_000_000_000_000 {
                metadata.append(Date(timeIntervalSince1970: milliseconds / 1000).formatted(date: .numeric, time: .standard))
            }
            if let priority = record["priority"].intValue, priority >= 0 {
                let facility = priority / 8
                metadata.append((facility < facilities.count ? facilities[facility] : "类别 \(facility)") + "." + severities[priority % 8])
            }
            return (metadata.isEmpty ? "" : metadata.joined(separator: " · ") + "\n") + message
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(record), let text = String(data: data, encoding: .utf8) else { return "无法显示此记录" }
        return text
    }
}
