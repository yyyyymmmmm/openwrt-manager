import SwiftUI
import OpenWrtKit

struct ConfigurationDirectoryView: View {
    @Environment(RouterStore.self) private var store
    @State private var query = ""
    var names: [String]? = nil
    var title = "全部配置"
    private var filtered: [String] {
        (names ?? store.inventory.configNames).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            InventoryStatus()
            AppSearchField(prompt: "搜索配置名称", text: $query)
            AppSection(title: store.inventory.configsRead || names != nil ? "配置 · \(filtered.count)" : "配置目录") {
                AppGroup {
                    ForEach(filtered, id: \.self) { name in
                        NavigationLink { ConfigurationEditorView(name: name) } label: {
                            AppRow(title: name, symbol: "slider.horizontal.3", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("configuration-\(name)")
                        if name != filtered.last { AppDivider() }
                    }
                }
            }
            if filtered.isEmpty && (store.inventory.configsRead || names != nil) { ContentUnavailableView.search(text: query) }
        }.appDetailStyle(title)
    }
}

struct ConfigurationEditorView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var original: RouterConfiguration?
    @State private var draft: RouterConfiguration?
    @State private var allowed = false
    @State private var loading = true
    @State private var error: String?
    @State private var accessError: String?
    @State private var showAddSection = false
    @State private var showDiscard = false
    @State private var showPreview = false
    @State private var preview: ConfigurationPlan?
    private var changed: Bool { draft != nil && draft != original }

    var body: some View {
        Form {
            if loading { ProgressView("正在读取配置…") }
            if let error { Section { Text(error).foregroundStyle(AppPalette.red); Button("重新读取") { Task { await load() } } } }
            if let draft {
                Section {
                    Label(allowed ? "允许编辑" : "当前账户仅可读取", systemImage: allowed ? "pencil" : "lock")
                        .font(AppTypography.secondary)
                } footer: {
                    Text("字段直接来自路由器配置。修改网络、管理访问或插件字段可能影响连接与服务。应用前请核对变更。")
                }
                if let accessError { Section { Text(accessError).foregroundStyle(AppPalette.orange) } }
                ForEach(draft.sections) { section in
                    Section {
                        NavigationLink {
                            ConfigurationSectionEditor(section: sectionBinding(section.id), allowed: allowed)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.id).font(AppTypography.rowTitle)
                                Text("\(section.type) · \(section.values.count) 个字段").font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                            }
                        }.accessibilityIdentifier("config-section-\(section.id)")
                    }
                }
                Section {
                    Button("新增配置节", systemImage: "plus") { showAddSection = true }.disabled(!allowed)
                    Button("预览变更", systemImage: "list.bullet.rectangle") {
                        do {
                            if let original, let value = self.draft {
                                preview = try ConfigurationPlan(original: original, edited: value); showPreview = true
                            }
                        } catch { self.error = FriendlyError.message(error) }
                    }.disabled(!changed || !allowed).accessibilityIdentifier("previewConfigChanges")
                }
            }
        }
        .font(AppTypography.row).tint(AppPalette.accent)
        .scrollContentBackground(.hidden).background(AppPalette.canvas)
        .appDetailStyle(name)
        .navigationBarBackButtonHidden(changed)
        .toolbar {
            if changed { ToolbarItem(placement: .topBarLeading) { Button("返回", systemImage: "chevron.left") { showDiscard = true } } }
        }
        .confirmationDialog("放弃未应用的修改？", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .sheet(isPresented: $showAddSection) {
            AddConfigurationSectionView(existing: Set(draft?.sections.map(\.id) ?? [])) { section in draft?.sections.append(section) }
        }
        .navigationDestination(isPresented: $showPreview) {
            if let preview { ConfigurationPreviewView(plan: preview, allowed: allowed) }
        }
        .task(id: store.connectionID) { await load() }
        .onChange(of: store.pendingConfiguration) { previous, current in
            if previous != nil && current == nil { Task { await load() } }
        }
    }

    private func sectionBinding(_ id: String) -> Binding<ConfigurationSection?> {
        Binding(get: { draft?.sections.first { $0.id == id } }, set: { updated in
            guard let index = draft?.sections.firstIndex(where: { $0.id == id }) else { return }
            if let updated { draft?.sections[index] = updated } else { draft?.sections.remove(at: index) }
        })
    }
    private func load() async {
        let generation = store.connectionID
        loading = true; error = nil; accessError = nil; allowed = false
        defer { loading = false }
        do {
            let value = try await store.configuration(name)
            guard generation == store.connectionID, !Task.isCancelled else { return }
            original = value; draft = value
            do {
                let access = try await store.canWriteConfiguration(name)
                guard generation == store.connectionID, !Task.isCancelled else { return }
                allowed = access
            } catch {
                guard generation == store.connectionID, !Task.isCancelled else { return }
                accessError = "写权限未能确认，当前仅可查看。" + FriendlyError.message(error)
            }
        } catch {
            guard generation == store.connectionID, !Task.isCancelled else { return }
            original = nil; draft = nil; self.error = FriendlyError.message(error)
        }
    }
}

private struct ConfigurationSectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var section: ConfigurationSection?
    let allowed: Bool
    @State private var editing: FieldDraft?
    @State private var confirmDelete = false
    var body: some View {
        Form {
            if let section {
                Section("\(section.type) · \(section.id)") {
                    ForEach(section.values.keys.sorted(), id: \.self) { key in
                        Button {
                            editing = FieldDraft(key: key, value: section.values[key] ?? .string(""), isNew: false)
                        } label: {
                            LabeledContent(key) {
                                Text(ConfigurationDisplay.value(section.values[key], key: key))
                                    .foregroundStyle(AppPalette.muted).lineLimit(2)
                            }.foregroundStyle(AppPalette.text)
                        }.disabled(!allowed).accessibilityIdentifier("config-field-\(key)")
                    }
                }
                Section {
                    Button("新增字段", systemImage: "plus") { editing = FieldDraft(key: "", value: .string(""), isNew: true) }
                    Button("删除配置节", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }.disabled(!allowed)
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("配置节")
            .sheet(item: $editing) { field in
                ConfigurationFieldEditor(field: field, existing: Set(section?.values.keys.map { $0 } ?? [])) { key, value in
                    section?.values[key] = value
                }
            }
            .confirmationDialog("删除此配置节及其全部字段？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除配置节", role: .destructive) { section = nil; dismiss() }
                Button("取消", role: .cancel) {}
            }
    }
}

private struct FieldDraft: Identifiable {
    let id = UUID()
    var key: String
    var value: JSONValue
    var isNew: Bool
}

private struct ConfigurationFieldEditor: View {
    @Environment(\.dismiss) private var dismiss
    let field: FieldDraft
    let existing: Set<String>
    let save: (String, JSONValue?) -> Void
    @State private var key: String
    @State private var text: String
    @State private var isList: Bool
    @State private var reveal = false
    @State private var emptyList = false
    @State private var confirmDelete = false
    init(field: FieldDraft, existing: Set<String>, save: @escaping (String, JSONValue?) -> Void) {
        self.field = field; self.existing = existing; self.save = save
        _key = State(initialValue: field.key)
        _isList = State(initialValue: field.value.arrayValue != nil)
        _text = State(initialValue: field.value.arrayValue?.compactMap(\.stringValue).joined(separator: "\n") ?? field.value.stringValue ?? "")
        _emptyList = State(initialValue: field.value.arrayValue?.isEmpty == true)
    }
    private var valid: Bool { InventoryParser.validIdentifier(key) && (!field.isNew || !existing.contains(key)) && !text.contains("\0") }
    var body: some View {
        NavigationStack {
            Form {
                Section("字段名称") { TextField("名称", text: $key).disabled(!field.isNew).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("configFieldName") }
                Section {
                    Picker("值类型", selection: $isList) { Text("文本").tag(false); Text("文本列表").tag(true) }.pickerStyle(.segmented)
                    if ConfigurationDisplay.sensitive(key) && !reveal {
                        SecureField("值", text: $text).accessibilityIdentifier("configValueInput")
                    } else {
                        TextField(isList ? "每行一项" : "值", text: $text, axis: .vertical)
                            .lineLimit(3...12).accessibilityIdentifier("configValueInput")
                    }
                    if ConfigurationDisplay.sensitive(key) { Toggle("显示内容", isOn: $reveal) }
                    if isList { Toggle("空列表", isOn: $emptyList) }
                } footer: { if isList { Text("每行是一项，保留原有顺序。空行代表一个空文本项。") } }
                if !field.isNew { Section { Button("删除字段", role: .destructive) { confirmDelete = true } } }
            }.font(AppTypography.row).textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle(field.isNew ? "新增字段" : key).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            let value: JSONValue = isList ? .array(emptyList ? [] : text.components(separatedBy: "\n").map(JSONValue.string)) : .string(text)
                            save(key, value); dismiss()
                        }.disabled(!valid)
                    }
                }
                .confirmationDialog("删除字段 \(key)？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除字段", role: .destructive) { save(key, nil); dismiss() }
                    Button("取消", role: .cancel) {}
                }
        }.tint(AppPalette.accent)
    }
}

private struct AddConfigurationSectionView: View {
    @Environment(\.dismiss) private var dismiss
    let existing: Set<String>
    let save: (ConfigurationSection) -> Void
    @State private var name = ""
    @State private var type = ""
    @State private var anonymous = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("节类型", text: $type)
                Toggle("匿名配置节", isOn: $anonymous)
                if !anonymous { TextField("节名称", text: $name) }
            }.font(AppTypography.row).textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle("新增配置节").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加") {
                            save(.init(id: anonymous ? "new_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") : name, type: type, anonymous: anonymous)); dismiss()
                        }.disabled(!InventoryParser.validIdentifier(type) || (!anonymous && (!InventoryParser.validIdentifier(name) || existing.contains(name))))
                    }
                }
        }.tint(AppPalette.accent)
    }
}

struct ConfigurationPreviewView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let plan: ConfigurationPlan
    let allowed: Bool
    @State private var error: String?
    @State private var applying = false
    @State private var confirm = false
    var body: some View {
        Form {
            Section("\(plan.original.name) · \(plan.edits.count) 项修改") {
                ForEach(Array(plan.edits.enumerated()), id: \.offset) { _, edit in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(edit.summary)
                        if case .set(_, let option, let value) = edit {
                            Text(ConfigurationDisplay.value(value, key: option)).foregroundStyle(AppPalette.muted).font(AppTypography.secondary)
                        }
                        if case .add(let section) = edit {
                            Text(section.anonymous ? "匿名配置节" : section.id).font(AppTypography.secondary)
                            ForEach(section.values.keys.sorted(), id: \.self) { key in
                                Text("\(key)：\(ConfigurationDisplay.value(section.values[key], key: key))")
                                    .foregroundStyle(AppPalette.muted).font(AppTypography.secondary)
                            }
                        }
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(AppPalette.red) } }
            Section {
                if applying { ProgressView("正在提交配置…") }
                Button("应用到路由器", systemImage: "checkmark.circle") { confirm = true }
                    .disabled(!allowed || applying || plan.edits.isEmpty || store.isMutating)
                    .accessibilityIdentifier("applyConfigurationButton")
            } footer: { Text("应用后需要在 90 秒内确认保留；连接中断时不要重复提交。路由器会尝试超时回滚。") }
        }.font(AppTypography.row).appDetailStyle("变更预览").tint(AppPalette.accent)
            .confirmationDialog("应用 \(plan.edits.count) 项配置修改？", isPresented: $confirm, titleVisibility: .visible) {
                Button("应用修改") {
                    Task {
                        applying = true
                        defer { applying = false }
                        do { try await store.applyConfiguration(plan); dismiss() }
                        catch { self.error = FriendlyError.message(error) }
                    }
                }
                Button("取消", role: .cancel) {}
            }
    }
}

struct PendingConfigurationView: View {
    @Environment(RouterStore.self) private var store
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                if let pending = store.pendingConfiguration {
                    Section {
                        Text(pending.acknowledged ? "配置已应用，等待确认" : "连接中断，应用结果待确认").font(AppTypography.navigation)
                        Text("请确认网络与管理功能可用，再保留修改。未确认时路由器会尝试自动回滚。")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("剩余 \(max(0, Int(pending.deadline.timeIntervalSince(context.date)))) 秒").monospacedDigit()
                        }
                    }
                    if let error { Section { Text(error).foregroundStyle(AppPalette.red) } }
                    Section {
                        if store.isMutating { ProgressView("正在联系路由器…") }
                        Button("验证连接并保留修改", systemImage: "checkmark.circle") { run { try await store.confirmConfiguration() } }
                        Button("回滚修改", systemImage: "arrow.uturn.backward", role: .destructive) { run { try await store.rollbackConfiguration() } }
                    }.disabled(store.isMutating)
                    if pending.deadline <= Date() {
                        Section {
                            Button("重新读取并核对配置") { Task { await store.releaseExpiredConfiguration() } }
                        } footer: { Text("超过期限不代表回滚已验证完成，请核对路由器实际配置。") }
                    }
                }
            }.font(AppTypography.row).navigationTitle("确认配置").navigationBarTitleDisplayMode(.inline)
                .task(id: store.pendingConfiguration?.deadline) {
                    guard let deadline = store.pendingConfiguration?.deadline else { return }
                    let duration = max(0, deadline.timeIntervalSinceNow)
                    try? await Task.sleep(for: .seconds(duration))
                    guard !Task.isCancelled else { return }
                    await store.releaseExpiredConfiguration()
                }
        }.tint(AppPalette.accent)
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation(); error = nil } catch { self.error = FriendlyError.message(error) } }
    }
}

enum ConfigurationDisplay {
    static func sensitive(_ key: String) -> Bool {
        ["password", "passwd", "secret", "token", "key", "credential", "proxy", "url", "param_enc", "param_opt"].contains { key.lowercased().contains($0) }
    }
    static func value(_ value: JSONValue?, key: String) -> String {
        if sensitive(key) { return "••••••••" }
        if let list = value?.arrayValue { return list.isEmpty ? "空列表" : list.compactMap(\.stringValue).joined(separator: " · ") }
        return value?.textValue ?? "空值"
    }
}
