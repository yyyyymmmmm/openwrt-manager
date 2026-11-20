import SwiftUI
import OpenWrtKit

/// Reload targets per config: after a verified apply the transaction
/// restarts these init.d services so the change takes effect.
enum ConfigReloadMap {
    static func services(for config: String) -> [String] {
        switch config {
        case "dhcp": return ["dnsmasq", "odhcpd"]
        case "firewall": return ["firewall"]
        case "network", "wireless": return ["network"]
        case "homeproxy": return ["homeproxy"]
        case "mosdns": return ["mosdns"]
        case "dropbear": return ["dropbear"]
        case "uhttpd": return ["uhttpd"]
        case "upnpd": return ["miniupnpd"]
        case "ddns": return ["ddns"]
        default: return []
        }
    }
}

// MARK: - Diff preview + confirmation (the L4 gate every write passes)

/// Shows exactly what will change (from the plan's diff), requires an
/// explicit confirmation, then runs the transaction and reports its real
/// outcome. No write in the app bypasses this sheet.
struct TransactionConfirmationView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let plan: ConfigurationPlan
    let reloadServices: [String]
    var onFinished: (() -> Void)? = nil

    @State private var phase: Phase = .preview
    @State private var resultMessage: String?

    private enum Phase { case preview, running, succeeded, failed }

    var body: some View {
        NavigationStack {
            List {
                Section("将要应用的修改（\(plan.original.name)）") {
                    if plan.edits.isEmpty {
                        Text("没有修改。").foregroundStyle(AppPalette.muted)
                    } else {
                        ForEach(Array(plan.edits.enumerated()), id: \.offset) { _, edit in
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(edit.summary).font(AppTypography.rowTitle)
                                if let detail = detail(for: edit) {
                                    Text(detail).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                                }
                            }
                        }
                    }
                }
                if !reloadServices.isEmpty {
                    Section {
                        Label("应用后将重启服务：\(reloadServices.joined(separator: "、"))，期间相关功能短暂中断。",
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                }
                switch phase {
                case .running:
                    HStack { ProgressView(); Text("正在下发、重载并回读验证…") }
                case .succeeded:
                    Label(resultMessage ?? "已完成", systemImage: "checkmark.circle")
                        .foregroundStyle(AppPalette.green)
                case .failed:
                    Label(resultMessage ?? "事务失败", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppPalette.orange)
                        .fixedSize(horizontal: false, vertical: true)
                case .preview:
                    EmptyView()
                }
            }
            .navigationTitle("确认修改")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .succeeded || phase == .failed ? "完成" : "取消") {
                        dismiss()
                        if phase == .succeeded { onFinished?() }
                    }
                    .disabled(phase == .running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认执行") { Task { await run() } }
                        .disabled(plan.edits.isEmpty || phase != .preview)
                }
            }
        }
    }

    private func detail(for edit: ConfigurationEdit) -> String? {
        func text(_ config: RouterConfiguration, section: String, option: String) -> String {
            guard let section = config.sections.first(where: { $0.id == section }),
                  let value = section.values[option] else { return "（无）" }
            return GenericPageModel.displayText(value)
        }
        switch edit {
        case .set(let section, let option, let value):
            return "\(text(plan.original, section: section, option: option)) → \(GenericPageModel.displayText(value))"
        case .removeOption(let section, let option):
            return "删除：\(text(plan.original, section: section, option: option))"
        case .removeSection(let section):
            return "删除整个配置节 \(section)"
        case .add(let section):
            return "新增 \(section.type) 配置节，共 \(section.values.count) 项"
        }
    }

    private func run() async {
        phase = .running
        do {
            let receipt = try await store.executeConfiguration(plan: plan, reloadServices: reloadServices)
            resultMessage = "已应用 \(receipt.editCount) 项修改并回读验证通过。"
            phase = .succeeded
        } catch {
            resultMessage = FriendlyError.message(error)
            phase = .failed
        }
    }
}

// MARK: - Structured configuration editor

/// Edits one UCI configuration as structured fields and produces a
/// ConfigurationPlan; saving goes through TransactionConfirmationView.
struct ConfigEditorView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let configName: String
    var title: String? = nil

    @State private var original: RouterConfiguration?
    @State private var draft: RouterConfiguration?
    @State private var error: String?
    @State private var plan: PlanPresentation?
    @State private var planError: String?

    var body: some View {
        List {
            if let error {
                ErrorStateView(message: error) { Task { await load() } }
            } else if let draft {
                ForEach(draft.sections) { section in
                    Section {
                        ForEach(section.values.keys.sorted(), id: \.self) { key in
                            fieldEditor(sectionID: section.id, key: key,
                                        value: section.values[key] ?? .null)
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                let key = section.values.keys.sorted()[offset]
                                removeOption(sectionID: section.id, key: key)
                            }
                        }
                        Button(role: .destructive) {
                            removeSection(section.id)
                        } label: {
                            Label("删除此配置节", systemImage: "trash")
                        }
                    } header: {
                        Text(section.anonymous ? section.type : "\(section.type) · \(section.id)")
                    }
                }
                Section {
                    Button {
                        addSection()
                    } label: {
                        Label("新增配置节", systemImage: "plus.circle")
                    }
                    if let planError {
                        Text(planError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                    }
                }
            } else {
                ProgressView("正在读取配置…")
            }
        }
        .navigationTitle(title ?? configName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { preparePlan() }
                    .disabled(draft == nil || draft == original)
            }
        }
        .task { await load() }
        .sheet(item: $plan) { presentation in
            TransactionConfirmationView(plan: presentation.plan,
                                        reloadServices: ConfigReloadMap.services(for: configName)) {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func fieldEditor(sectionID: String, key: String, value: JSONValue) -> some View {
        switch value {
        case .bool(let flag):
            Toggle(key, isOn: Binding(
                get: { flag },
                set: { setValue(sectionID: sectionID, key: key, value: .bool($0)) }))
        case .array(let items):
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(key).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                TextField(key, text: Binding(
                    get: { items.map { GenericPageModel.displayText($0) }.joined(separator: "\n") },
                    set: { newText in
                        let lines = newText.split(separator: "\n", omittingEmptySubsequences: false)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                        setValue(sectionID: sectionID, key: key,
                                 value: .array(lines.filter { !$0.isEmpty }.map(JSONValue.string)))
                    }), axis: .vertical)
                    .font(AppTypography.row)
            }
        default:
            HStack {
                Text(key).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                Spacer()
                TextField(key, text: Binding(
                    get: { GenericPageModel.displayText(value) == "—" ? "" : GenericPageModel.displayText(value) },
                    set: { setValue(sectionID: sectionID, key: key, value: .string($0)) }))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
    }

    private func setValue(sectionID: String, key: String, value: JSONValue) {
        guard let index = draft?.sections.firstIndex(where: { $0.id == sectionID }) else { return }
        draft?.sections[index].values[key] = value
    }

    private func removeOption(sectionID: String, key: String) {
        guard let index = draft?.sections.firstIndex(where: { $0.id == sectionID }) else { return }
        draft?.sections[index].values[key] = nil
    }

    private func removeSection(_ id: String) {
        draft?.sections.removeAll { $0.id == id }
    }

    private func addSection() {
        guard var draft else { return }
        let type = draft.sections.last?.type ?? "section"
        var number = draft.sections.count + 1
        var id = "cfg\(number)"
        while draft.sections.contains(where: { $0.id == id }) { number += 1; id = "cfg\(number)" }
        draft.sections.append(ConfigurationSection(id: id, type: type, anonymous: true, values: [:]))
        self.draft = draft
    }

    private func preparePlan() {
        guard let original, let draft else { return }
        do {
            plan = try PlanPresentation(plan: ConfigurationPlan(original: original, edited: draft))
            planError = nil
        } catch {
            planError = FriendlyError.message(error)
        }
    }

    private func load() async {
        do {
            let configuration = try await store.configuration(configName)
            original = configuration
            draft = configuration
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}

/// Presentation wrapper: ConfigurationPlan has no identity of its own,
/// so the sheet keys on the config name plus the diff itself.
struct PlanPresentation: Identifiable {
    let plan: ConfigurationPlan
    var id: String { "\(plan.original.name)|\(plan.edits.map(\.summary).joined(separator: ";"))" }
}

// MARK: - DHCP static lease editor

/// Dedicated editor for static DHCP leases (host sections of the dhcp
/// config): add, edit and delete go through one transaction.
struct StaticLeaseEditorView: View {
    @Environment(RouterStore.self) private var store
    @State private var original: RouterConfiguration?
    @State private var hosts: [ConfigurationSection] = []
    @State private var error: String?
    @State private var plan: PlanPresentation?
    @State private var planError: String?

    var body: some View {
        List {
            if let error {
                ErrorStateView(message: error) { Task { await load() } }
            } else if original != nil {
                ForEach($hosts) { $host in
                    Section(host.values["name"]?.stringValue ?? host.id) {
                        TextField("主机名", text: binding($host, "name"))
                        TextField("MAC 地址", text: binding($host, "mac"))
                        TextField("IPv4 地址", text: binding($host, "ip"))
                        Button(role: .destructive) {
                            hosts.removeAll { $0.id == host.id }
                        } label: {
                            Label("删除此租约", systemImage: "trash")
                        }
                    }
                }
                Section {
                    Button {
                        var number = hosts.count + 1
                        var id = "host\(number)"
                        while hosts.contains(where: { $0.id == id }) { number += 1; id = "host\(number)" }
                        hosts.append(ConfigurationSection(id: id, type: "host", anonymous: true,
                                                          values: ["name": .string(""), "mac": .string(""), "ip": .string("")]))
                    } label: {
                        Label("新增静态租约", systemImage: "plus.circle")
                    }
                    if let planError {
                        Text(planError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                    }
                }
            } else {
                ProgressView("正在读取租约…")
            }
        }
        .navigationTitle("静态租约")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { preparePlan() }.disabled(original == nil)
            }
        }
        .task { await load() }
        .sheet(item: $plan) { presentation in
            TransactionConfirmationView(plan: presentation.plan, reloadServices: ConfigReloadMap.services(for: "dhcp"))
        }
    }

    private func binding(_ host: Binding<ConfigurationSection>, _ key: String) -> Binding<String> {
        Binding(
            get: { host.wrappedValue.values[key]?.stringValue ?? "" },
            set: { host.wrappedValue.values[key] = .string($0) })
    }

    private func preparePlan() {
        guard let original else { return }
        var edited = original
        edited.sections = original.sections.filter { $0.type != "host" } + hosts
        do {
            plan = try PlanPresentation(plan: ConfigurationPlan(original: original, edited: edited))
            planError = nil
        } catch {
            planError = FriendlyError.message(error)
        }
    }

    private func load() async {
        do {
            let configuration = try await store.configuration("dhcp")
            original = configuration
            hosts = configuration.sections.filter { $0.type == "host" }
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}

// MARK: - Pending transaction resolution

/// Shown when an apply's outcome could not be confirmed (connection lost
/// mid-apply): the user explicitly keeps or rolls back — the app never
/// guesses.
struct PendingConfigurationView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let pending = store.pendingConfiguration {
                    Section {
                        Label("「\(pending.config)」的修改已下发但结果未确认。验证连接正常后保留修改，或立即回滚。",
                              systemImage: "exclamationmark.triangle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error {
                        ErrorStateView(message: error)
                    }
                    Section {
                        Button("验证连接并保留修改") { Task { await run { try await store.confirmConfiguration() } } }
                            .disabled(working)
                        Button("回滚修改", role: .destructive) { Task { await run { try await store.rollbackConfiguration() } } }
                            .disabled(working)
                    }
                }
            }
            .navigationTitle("待确认的配置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) async {
        working = true
        defer { working = false }
        do {
            try await operation()
            dismiss()
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}
