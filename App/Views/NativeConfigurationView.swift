import SwiftUI
import OpenWrtKit
import Darwin

/// Dedicated sections and labelled fields backed by the existing UCI rollback transaction.
struct NativeConfigurationView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let schema: NativeConfigurationSchema
    @State private var original: RouterConfiguration?
    @State private var draft: RouterConfiguration?
    @State private var writable = false
    @State private var loading = false
    @State private var error: String?
    @State private var permissionError: String?
    @State private var protocols: [String] = []
    @State private var protocolError: String?
    @State private var homeProxyCapabilities: HomeProxyCapabilities?
    @State private var homeProxyCapabilityError: String?
    @State private var adding: NativeSectionSchema?
    @State private var discard = false
    @State private var preview: ConfigurationPlan?
    @State private var showPreview = false
    @State private var submitted = false
    private var changed: Bool { draft != nil && draft != original }
    private var editable: Bool { writable && !store.isMutating && store.pendingConfiguration == nil }
    private var sectionSchemas: [NativeSectionSchema] {
        let resolved = schema.resolvedPluginSections(configuration: draft, capabilities: homeProxyCapabilities)
        guard schema.id == "interfaces", let draft else { return resolved }
        let interfaces = draft.sections.filter { $0.type == "interface" && $0.values["proto"]?.stringValue == "wireguard" }.map(\.id)
        let peers = draft.sections.filter { $0.type.hasPrefix("wireguard_") }.map { String($0.type.dropFirst(10)) }
        return resolved + Set(interfaces + peers).sorted().map { NativeConfigurationSchema.wireguardPeers(interface: $0) }
    }

    var body: some View {
        Form {
            if loading { ProgressView("正在读取\(schema.title)…") }
            if let error {
                Section { Text(error).foregroundStyle(AppPalette.red); Button("重新读取") { Task { await load() } } }
            }
            if let draft {
                Section {
                    Label(writable ? "允许编辑" : "当前仅可查看", systemImage: writable ? "pencil" : "lock")
                    if let permissionError { Text(permissionError).foregroundStyle(AppPalette.orange) }
                    if let protocolError { Text(protocolError).foregroundStyle(AppPalette.orange) }
                    if let homeProxyCapabilityError { Text(homeProxyCapabilityError).foregroundStyle(AppPalette.orange) }
                } footer: { Text(schema.note) }
                ForEach(sectionSchemas) { sectionSchema in
                    let sections = draft.sections.filter { sectionSchema.matches($0) }
                    Section(sectionSchema.title) {
                        ForEach(sections) { section in
                            NavigationLink {
                                NativeSectionView(schema: sectionSchema, section: sectionBinding(section.id),
                                                  editable: editable, protocols: protocols)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(sectionSchema.label(section)).font(AppTypography.rowTitle)
                                    Text(section.anonymous ? sectionSchema.title : section.id)
                                        .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                                }
                            }.accessibilityIdentifier("native-section-\(schema.id)-\(section.id)")
                        }
                        if sections.isEmpty { Text("路由器未返回此类配置").foregroundStyle(AppPalette.muted) }
                        if sectionSchema.addable {
                            Button("新增\(sectionSchema.title)", systemImage: "plus") { adding = sectionSchema }
                                .disabled(!editable).accessibilityIdentifier("native-add-\(schema.id)-\(sectionSchema.type)")
                        }
                    }
                }
                Section {
                    Button("预览变更", systemImage: "list.bullet.rectangle") { makePreview() }
                        .disabled(!editable || !changed).accessibilityIdentifier("native-preview-\(schema.id)")
                } footer: { Text("新增、修改和删除先保存在本页草稿中。预览后仍需明确应用；应用使用路由器的确认与超时回滚流程。") }
            }
        }
        .font(AppTypography.row).tint(AppPalette.accent)
        .scrollContentBackground(.hidden).background(AppPalette.canvas).appDetailStyle(schema.title)
        .navigationBarBackButtonHidden(changed)
        .toolbar {
            if changed { ToolbarItem(placement: .topBarLeading) { Button("返回", systemImage: "chevron.left") { discard = true } } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(changed || loading || store.pendingConfiguration != nil)
            }
        }
        .confirmationDialog("放弃未应用的修改？", isPresented: $discard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .sheet(item: $adding) { sectionSchema in
            NativeAddSectionView(schema: sectionSchema, existing: Set(draft?.sections.map(\.id) ?? []), protocols: protocols) { section in
                draft?.sections.append(section)
            }
        }
        .navigationDestination(isPresented: $showPreview) {
            if let preview { ConfigurationPreviewView(plan: preview, allowed: writable, onApplied: { submitted = true }) }
        }
        .task(id: store.connectionID) { await load() }
        .onChange(of: store.pendingConfiguration) { previous, current in
            if previous != nil && current == nil && (submitted || !changed) {
                submitted = false; Task { await load() }
            }
        }
    }

    private func sectionBinding(_ id: String) -> Binding<ConfigurationSection?> {
        Binding(get: { draft?.sections.first { $0.id == id } }, set: { value in
            guard let index = draft?.sections.firstIndex(where: { $0.id == id }) else { return }
            if let value { draft?.sections[index] = value } else { draft?.sections.remove(at: index) }
        })
    }
    private func makePreview() {
        do {
            guard let original, let draft else { return }
            let effectiveSchema = NativeConfigurationSchema(id: schema.id, title: schema.title, config: schema.config, sections: sectionSchemas, note: schema.note)
            try NativeValidation.validate(original: original, draft: draft, schema: effectiveSchema)
            preview = try ConfigurationPlan(original: original, edited: draft)
            error = nil; showPreview = true
        } catch { self.error = error.localizedDescription }
    }
    private func load() async {
        let generation = store.connectionID
        loading = true; error = nil; permissionError = nil; writable = false
        protocols = []; protocolError = nil; homeProxyCapabilities = nil; homeProxyCapabilityError = nil
        defer { if generation == store.connectionID { loading = false } }
        do {
            let value = try await store.configuration(schema.config)
            guard generation == store.connectionID, !Task.isCancelled else { return }
            original = value; draft = value
            do {
                let allowed = try await store.canWriteConfiguration(schema.config)
                guard generation == store.connectionID, !Task.isCancelled else { return }
                writable = allowed
            } catch {
                guard generation == store.connectionID, !Task.isCancelled else { return }
                permissionError = "无法确认写权限：" + FriendlyError.message(error)
            }
            if schema.id == "interfaces" {
                do {
                    let reported = try await store.networkProtocols()
                    guard generation == store.connectionID, !Task.isCancelled else { return }
                    protocols = reported
                } catch {
                    guard generation == store.connectionID, !Task.isCancelled else { return }
                    protocolError = "协议能力读取失败，保留现有协议：" + FriendlyError.message(error)
                }
            }
            if schema.id == "homeproxy" {
                do {
                    let capabilities = try await store.homeProxyCapabilities()
                    guard generation == store.connectionID, !Task.isCancelled else { return }
                    homeProxyCapabilities = capabilities
                } catch {
                    guard generation == store.connectionID, !Task.isCancelled else { return }
                    homeProxyCapabilityError = "未能确认 sing-box 能力，节点、DNS 类型和代理模式不会列出假定选项：" + FriendlyError.message(error)
                }
            }
        } catch {
            guard generation == store.connectionID, !Task.isCancelled else { return }
            original = nil; draft = nil; self.error = FriendlyError.message(error)
        }
    }
}

private struct NativeSectionView: View {
    @Environment(\.dismiss) private var dismiss
    let schema: NativeSectionSchema
    @Binding var section: ConfigurationSection?
    let editable: Bool
    let protocols: [String]
    @State private var deleting = false
    var body: some View {
        Form {
            if let section {
                Section {
                    ForEach(schema.groups.filter { $0.fields.contains { $0.visible(in: section) } }) { group in
                        NavigationLink(group.title) {
                            NativeFieldGroupView(group: group, section: $section, editable: editable, protocols: protocols)
                        }.accessibilityIdentifier("native-group-\(schema.type)-\(group.id)")
                    }
                } header: { Text(schema.label(section)) } footer: {
                    Text("仅修改明确编辑的字段；未适配的固件扩展字段保留原值。删除配置节会删除其全部字段。")
                }
                if schema.addable { Section {
                    Button("删除\(schema.title)", systemImage: "trash", role: .destructive) { deleting = true }
                        .disabled(!editable).accessibilityIdentifier("native-delete-\(section.id)")
                } }
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle(schema.title)
            .confirmationDialog("从草稿中删除此\(schema.title)？", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除", role: .destructive) { section = nil; dismiss() }
                Button("取消", role: .cancel) {}
            } message: { Text("需要在上一级预览并应用后才会修改路由器。") }
    }
}

private struct NativeFieldGroupView: View {
    let group: NativeFieldGroup
    @Binding var section: ConfigurationSection?
    let editable: Bool
    let protocols: [String]
    @State private var editing: NativeField?
    private var visibleFields: [NativeField] {
        guard let section else { return [] }
        return group.fields.filter { $0.visible(in: section) }
    }
    var body: some View {
        Form {
            if let section {
                Section {
                    ForEach(visibleFields) { field in
                        Button { editing = effective(field) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(field.title).foregroundStyle(AppPalette.text)
                                Text(summary(field, value: section.values[field.id]))
                                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted).lineLimit(3)
                                if let reason = field.editingUnavailableReason {
                                    Text(reason).font(AppTypography.secondary).foregroundStyle(AppPalette.orange)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.disabled(!editable || field.editingUnavailableReason != nil || (section.type == "interface" && field.id == "proto" && protocols.isEmpty))
                            .accessibilityIdentifier("native-field-\(field.id)")
                    }
                } footer: { Text(editable ? "选择一项修改。未设置表示交由路由器固件处理。" : "当前账户没有已确认的写权限。") }
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle(group.title)
            .sheet(item: $editing) { field in
                NativeFieldEditor(field: field, value: section?.values[field.id]) { value in
                    section?.values[field.id] = value
                }
            }
    }
    private func effective(_ field: NativeField) -> NativeField {
        guard field.id == "proto" && section?.type == "interface" else { return field }
        var field = field; field.kind = .choice(protocols); return field
    }
    private func summary(_ field: NativeField, value: JSONValue?) -> String {
        guard let value else { return "未设置（使用固件默认）" }
        if case .flag = field.kind, let text = value.stringValue {
            if ["1", "true", "yes", "on"].contains(text) { return "启用" }
            if ["0", "false", "no", "off"].contains(text) { return "关闭" }
        }
        return ConfigurationDisplay.value(value, key: field.id)
    }
}

private struct NativeFieldEditor: View {
    @Environment(\.dismiss) private var dismiss
    let field: NativeField
    let value: JSONValue?
    let save: (JSONValue?) -> Void
    @State private var isSet: Bool
    @State private var text: String
    @State private var reveal = false
    @State private var error: String?
    init(field: NativeField, value: JSONValue?, save: @escaping (JSONValue?) -> Void) {
        self.field = field; self.value = value; self.save = save
        _isSet = State(initialValue: value != nil)
        _text = State(initialValue: value?.arrayValue?.compactMap(\.stringValue).joined(separator: "\n") ?? value?.stringValue ?? "")
    }
    private var edited: JSONValue? {
        guard isSet else { return nil }
        let originalText = value?.arrayValue?.compactMap(\.stringValue).joined(separator: "\n") ?? value?.stringValue ?? ""
        if let value, text == originalText { return value }
        if case .list = field.kind { return .array(text.split(separator: "\n", omittingEmptySubsequences: true).map { .string(String($0).trimmingCharacters(in: .whitespaces)) }) }
        return .string(text)
    }
    private var changed: Bool { edited != value }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("明确设置此项", isOn: $isSet)
                } footer: { Text("关闭后移除该字段，交由固件使用其默认行为；不会替你填入默认值。") }
                if isSet {
                    Section(field.title) {
                        input
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("native-value-\(field.id)")
                        if case .secret = field.kind { Toggle("显示内容", isOn: $reveal) }
                    }
                }
                if !field.help.isEmpty { Section { Text(field.help).foregroundStyle(AppPalette.muted) } }
                if let error { Section { Text(error).foregroundStyle(AppPalette.red) } }
            }.font(AppTypography.row).tint(AppPalette.accent).navigationTitle(field.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("存入草稿") {
                            do { try NativeValidation.validate(field, value: edited); save(edited); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }.disabled(!changed).accessibilityIdentifier("native-save-field")
                    }
                }.interactiveDismissDisabled(changed)
        }
    }
    @ViewBuilder private var input: some View {
        switch field.kind {
        case .secret:
            if reveal { TextField("内容", text: $text) } else { SecureField("内容", text: $text) }
        case .flag:
            Picker("值", selection: $text) {
                Text("请选择").tag("")
                Text("启用").tag("1"); Text("关闭").tag("0")
                if !["", "1", "0"].contains(text) { Text("当前值：\(text)").tag(text) }
            }
        case .choice(let options):
            Picker("值", selection: $text) {
                if options.contains("") { Text(field.choiceLabels[""] ?? "未设置").tag("") }
                else if text.isEmpty { Text("请选择").tag("") }
                ForEach(Array(Set(options + (text.isEmpty ? [] : [text]))).sorted(), id: \.self) { option in
                    if !option.isEmpty { Text(field.choiceLabels[option] ?? option).tag(option) }
                }
            }
        case .list:
            TextField("每行一项", text: $text, axis: .vertical).lineLimit(4...14)
        case .integer:
            TextField("数值", text: $text).keyboardType(.numbersAndPunctuation)
        default:
            TextField("内容", text: $text, axis: .vertical).lineLimit(1...6)
        }
    }
}

private struct NativeAddSectionView: View {
    @Environment(\.dismiss) private var dismiss
    let schema: NativeSectionSchema
    let existing: Set<String>
    let protocols: [String]
    let save: (ConfigurationSection) -> Void
    @State private var name = ""
    @State private var section: ConfigurationSection?
    @State private var error: String?
    init(schema: NativeSectionSchema, existing: Set<String>, protocols: [String], save: @escaping (ConfigurationSection) -> Void) {
        self.schema = schema; self.existing = existing; self.protocols = protocols; self.save = save
        _section = State(initialValue: ConfigurationSection(id: "draft_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""), type: schema.type, anonymous: !schema.named))
    }
    var body: some View {
        NavigationStack {
            Form {
                if schema.named {
                    Section("配置标识") { TextField("唯一名称", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled() }
                }
                ForEach(schema.groups.filter { group in section.map { current in group.fields.contains { $0.visible(in: current) } } ?? false }) { group in
                    NavigationLink(group.title) { NativeFieldGroupView(group: group, section: $section, editable: true, protocols: protocols) }
                }
                if let error { Section { Text(error).foregroundStyle(AppPalette.red) } }
            }.font(AppTypography.row).navigationTitle("新增\(schema.title)").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("存入草稿") {
                            do {
                                guard var section else { return }
                                if schema.named {
                                    guard InventoryParser.validIdentifier(name), !existing.contains(name) else { throw ConfigurationError.invalidIdentifier }
                                    section.id = name
                                }
                                try NativeValidation.validate(section: section, schema: schema)
                                save(section); dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }.tint(AppPalette.accent).interactiveDismissDisabled()
        }
    }
}

private enum NativeValidation {
    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func validate(original: RouterConfiguration, draft: RouterConfiguration, schema: NativeConfigurationSchema) throws {
        for section in draft.sections {
            guard let definition = schema.sections.first(where: { $0.matches(section) }) else { continue }
            let old = original.sections.first { $0.id == section.id }
            if old == nil { try validate(section: section, schema: definition) }
            else if let old {
                for field in definition.fields {
                    let changed = old.values[field.id] != section.values[field.id]
                    let newlyRequired = field.required && field.visible(in: section) && !field.visible(in: old)
                    guard changed || newlyRequired else { continue }
                    if changed && field.editingUnavailableReason != nil {
                        throw Invalid(message: "无法确认\(field.title)能力，请重新读取后编辑。")
                    }
                    try validate(field, value: section.values[field.id])
                }
            }
            if schema.id == "zerotier", section.type == "network", let networkID = section.values["id"]?.stringValue,
               draft.sections.filter({ $0.type == "network" && $0.values["id"]?.stringValue?.lowercased() == networkID.lowercased() }).count > 1 {
                throw Invalid(message: "ZeroTier 网络 ID 重复，请保留一个网络配置。")
            }
        }
    }
    static func validate(section: ConfigurationSection, schema: NativeSectionSchema) throws {
        for field in schema.fields where field.visible(in: section) { try validate(field, value: section.values[field.id]) }
    }
    static func validate(_ field: NativeField, value: JSONValue?) throws {
        guard let value else {
            if field.required { throw Invalid(message: "请填写\(field.title)。") }
            return
        }
        let texts: [String]
        if let list = value.arrayValue {
            guard list.allSatisfy({ $0.stringValue != nil }) else { throw ConfigurationError.invalidValue }
            texts = list.compactMap(\.stringValue)
        } else if let text = value.stringValue { texts = [text] }
        else { throw ConfigurationError.invalidValue }
        guard texts.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 65536 }) else { throw ConfigurationError.invalidValue }
        if field.required && (texts.isEmpty || texts.allSatisfy(\.isEmpty)) { throw Invalid(message: "请填写\(field.title)。") }
        for text in texts {
            if ["private_key", "public_key", "preshared_key", "wireguard_private_key", "wireguard_peer_public_key", "wireguard_pre_shared_key"].contains(field.id), !text.isEmpty,
               Data(base64Encoded: text)?.count != 32 {
                throw Invalid(message: "\(field.title)必须是 Base64 编码的 32 字节 WireGuard 密钥。")
            }
            let valid: Bool
            switch field.kind {
            case .integer(let low, let high): valid = Int(text).map { (low...high).contains($0) } ?? false
            case .address: valid = address(text)
            case .prefix:
                valid = prefix(text)
            case .mac:
                valid = mac(text)
            case .netmask4:
                var v4 = in_addr()
                let parsed = text.withCString { inet_pton(AF_INET, $0, &v4) == 1 }
                let inverse = ~UInt32(bigEndian: v4.s_addr)
                valid = parsed && inverse & (inverse &+ 1) == 0
            case .flag: valid = ["1", "0", "true", "false", "on", "off", "yes", "no"].contains(text)
            case .hexadecimal(let count): valid = text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
            case .choice(let options): valid = !text.isEmpty || options.contains("")
            default: valid = true
            }
            if !valid { throw Invalid(message: "\(field.title)的格式或范围不正确。") }
            if let rule = field.items {
                let validItem: Bool
                switch rule {
                case .address: validItem = address(text)
                case .prefix: validItem = prefix(text)
                case .mac: validItem = mac(text)
                }
                if !validItem { throw Invalid(message: "\(field.title)包含无效条目。请每行填写一项。") }
            }
            if field.id == "ipaddr", text.contains(":") {
                throw Invalid(message: "IPv4 地址中不能填写 IPv6。请使用 IPv6 地址字段。")
            }
            if ["ip6addr", "ip6gw"].contains(field.id), !text.contains(":") {
                throw Invalid(message: "请在\(field.title)中填写 IPv6 地址。")
            }
        }
    }
    private static func prefix(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), address(String(parts[0])) else { return false }
        return parts.count == 1 || Int(parts[1]).map { (0...(parts[0].contains(":") ? 128 : 32)).contains($0) } == true
    }
    private static func mac(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }
    private static func address(_ text: String) -> Bool {
        var v4 = in_addr(); var v6 = in6_addr()
        return text.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}
