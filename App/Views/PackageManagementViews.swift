import SwiftUI
import OpenWrtKit

private enum PackageDisplayMode: String, CaseIterable, Identifiable {
    case available = "可用", installed = "已安装", changes = "更新"
    var id: String { rawValue }
}

struct PackagesView: View {
    @Environment(RouterStore.self) private var store
    @State private var query = ""
    @State private var mode = PackageDisplayMode.installed
    @State private var updateRequest: PackageRequest?

    private var packages: [InstalledPackage]? {
        switch mode {
        case .available: return store.packageAvailable?.packages
        case .installed: return store.packageInstalled?.packages
        case .changes:
            guard let installed = store.packageInstalled, let available = store.packageAvailable else { return nil }
            let versions = Dictionary(installed.packages.map { ($0.name, $0.version) }, uniquingKeysWith: { first, _ in first })
            return available.packages.filter { versions[$0.name] != nil && versions[$0.name] != $0.version }
        }
    }
    private var filtered: [InstalledPackage] {
        (packages ?? []).filter { query.isEmpty || ($0.name + " " + $0.description).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                Picker("软件包范围", selection: $mode) {
                    ForEach(PackageDisplayMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("package-mode")
                PackageReadStatus()
                if store.isReadingPackages { ProgressView("正在读取路由器软件包…") }
                Button("重新读取清单", systemImage: "arrow.clockwise") { Task { await store.refreshPackageLists() } }
                    .disabled(store.isReadingPackages || store.isMutating).accessibilityIdentifier("package-refresh")
                Button("更新软件源清单", systemImage: "arrow.down.circle") { updateRequest = PackageRequest(operation: .updateLists) }
                    .disabled(store.isMutating || store.isReadingPackages || store.packageRecheckRequired)
                    .accessibilityIdentifier("package-update-lists")
                if !store.packageTasks.isEmpty {
                    NavigationLink("本次会话的软件包任务") { PackageTasksView() }.accessibilityIdentifier("package-tasks")
                }
            }
            if mode == .changes {
                Section { Text("列出已安装版本与软件源版本不同的包，可能包含降级或不同构建。固件包管理器最终决定实际操作；不提供整机批量升级。更新基础组件或内核模块前请核对固件版本及兼容性。").font(AppTypography.secondary).foregroundStyle(.secondary) }
            }
            Section(packages == nil ? mode.rawValue + " · 尚未读取" : mode.rawValue + " · \(filtered.count)") {
                ForEach(filtered) { package in
                    NavigationLink { PackageDetailView(package: package) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(package.name).font(AppTypography.rowTitle)
                            Text(package.version).font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                            if !package.description.isEmpty { Text(package.description).font(AppTypography.secondary).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }.accessibilityIdentifier("package-\(package.name)")
                }
                if packages == nil && !store.isReadingPackages {
                    Text("清单尚未成功读取，请查看具体错误后重试。").foregroundStyle(.secondary)
                } else if packages != nil && filtered.isEmpty && !store.isReadingPackages {
                    Text(query.isEmpty ? (mode == .changes ? "当前返回清单中没有版本不同的包。" : "当前接口返回的清单为空。") : "没有匹配的软件包。")
                        .foregroundStyle(.secondary)
                }
            }
        }.font(AppTypography.row).appDetailStyle("软件包")
            .searchable(text: $query, prompt: "搜索名称或说明")
            .refreshable { await store.refreshPackageLists() }
            .task(id: store.connectionID) { if store.packageInstalled == nil { await store.refreshPackageLists() } }
            .sheet(item: $updateRequest) { request in PackageConfirmationView(request: request) }
    }
}

private struct PackageReadStatus: View {
    @Environment(RouterStore.self) private var store
    var body: some View {
        if let installed = store.packageInstalled {
            LabeledContent("已安装 · " + installed.backend.rawValue) { Text(installed.readAt, style: .time) }
        }
        if let available = store.packageAvailable {
            LabeledContent("软件源 · " + available.backend.rawValue) { Text(available.readAt, style: .time) }
        }
        if let error = store.packageInstalledError { Label("已安装清单：" + error, systemImage: "exclamationmark.triangle").foregroundStyle(AppPalette.orange) }
        if let error = store.packageAvailableError { Label("软件源清单：" + error, systemImage: "exclamationmark.triangle").foregroundStyle(AppPalette.orange) }
        if store.packageInstalledError != nil || store.packageAvailableError != nil {
            Text("失败时保留上次数据；不能将上次清单当作当前状态。操作前将重新核对版本。").font(AppTypography.secondary).foregroundStyle(.secondary)
        }
        if store.packageRecheckRequired {
            Text("上次请求结果未确认。请重新读取两份清单并检查路由器日志；自动重读失败时暂不允许继续提交软件包操作。").foregroundStyle(AppPalette.orange)
        }
    }
}

struct PackageDetailView: View {
    @Environment(RouterStore.self) private var store
    let package: InstalledPackage
    @State private var request: PackageRequest?
    private var installed: InstalledPackage? { store.packageInstalled?.packages.first { $0.name == package.name } }
    private var available: InstalledPackage? { store.packageAvailable?.packages.first { $0.name == package.name } }
    private var metadata: InstalledPackage { installed ?? available ?? package }
    private var dependents: [InstalledPackage] {
        (store.packageInstalled?.packages ?? []).filter { item in
            item.dependencies.contains { dependency in
                dependency.components(separatedBy: CharacterSet(charactersIn: "<>=~ (|")).first == package.name
            }
        }
    }
    private var canSubmit: Bool {
        store.packageInstalled != nil && store.packageInstalledError == nil && !store.isReadingPackages &&
        !store.isMutating && store.pendingConfiguration == nil && !store.packageRecheckRequired
    }
    var body: some View {
        List {
            Section("软件包") {
                LabeledContent("名称", value: package.name)
                LabeledContent("已安装", value: installed?.version ?? (store.packageInstalled == nil ? "尚未读取" : "当前清单未发现"))
                LabeledContent("软件源版本", value: available?.version ?? (store.packageAvailable == nil ? "尚未读取" : "当前清单未发现"))
                if let architecture = metadata.architecture { LabeledContent("架构", value: architecture) }
                if let size = metadata.installedSize { LabeledContent("安装大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .binary)) }
                if let size = available?.downloadSize { LabeledContent("下载大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .binary)) }
                if metadata.essential == true { Label("固件标记为必需组件", systemImage: "lock.shield") }
                if !metadata.description.isEmpty { Text(metadata.description) }
            }
            Section("操作") {
                if let installed {
                    if let available, installed.version != available.version {
                        Button("升级或核对软件源版本") { request = PackageRequest(operation: .upgrade(package.name), installed: installed, available: available) }
                            .disabled(!canSubmit || store.packageAvailableError != nil).accessibilityIdentifier("package-upgrade")
                    }
                    Button("卸载软件包", role: .destructive) { request = PackageRequest(operation: .remove(package.name), installed: installed, available: available) }
                        .disabled(!canSubmit || installed.essential == true).accessibilityIdentifier("package-remove")
                } else if let available {
                    Button("安装软件包") { request = PackageRequest(operation: .install(package.name), available: available) }
                        .disabled(!canSubmit || store.packageAvailableError != nil).accessibilityIdentifier("package-install")
                }
                Button("重新读取清单", systemImage: "arrow.clockwise") { Task { await store.refreshPackageLists() } }
                    .disabled(store.isReadingPackages || store.isMutating)
                NavigationLink("软件包任务与实际输出") { PackageTasksView() }
                PackageReadStatus()
            }
            if !metadata.dependencies.isEmpty {
                Section("返回的依赖 · \(metadata.dependencies.count)") {
                    ForEach(Array(metadata.dependencies.enumerated()), id: \.offset) { _, dependency in Text(dependency) }
                }
            }
            if !dependents.isEmpty {
                Section("直接引用此包的已安装软件 · \(dependents.count)") {
                    ForEach(dependents) { dependent in
                        NavigationLink(dependent.name) { PackageDetailView(package: dependent) }
                    }
                }
            }
            Section { Text("依赖清单只反映固件返回的元数据；虚拟包、间接依赖及最终依赖求解由包管理器处理。不启用强制覆盖、强制删除依赖或忽略签名。").font(AppTypography.secondary).foregroundStyle(.secondary) }
            if !metadata.files.isEmpty {
                Section("返回的安装文件 · \(metadata.files.count)") {
                    ForEach(Array(metadata.files.enumerated()), id: \.offset) { _, file in Text(file).font(AppTypography.secondary) }
                }
            }
        }.font(AppTypography.row).textSelection(.enabled).appDetailStyle(package.name)
            .task(id: store.connectionID) { if store.packageInstalled == nil { await store.refreshPackageLists() } }
            .sheet(item: $request) { request in PackageConfirmationView(request: request) }
    }
}

private struct PackageRequest: Identifiable {
    let id = UUID()
    let operation: PackageOperation
    var installed: InstalledPackage?
    var available: InstalledPackage?
}

private struct PackageConfirmationView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: PackageRequest
    @State private var allowed: Bool?
    @State private var accessError: String?
    @State private var submitted = false
    @State private var taskID: UUID?
    var body: some View {
        NavigationStack {
            List {
                Section("确认路由器与操作") {
                    LabeledContent("路由器", value: store.activeProfile?.name ?? "未连接")
                    if let address = store.activeProfile?.address { Text(address).font(AppTypography.secondary) }
                    LabeledContent("操作", value: request.operation.title)
                    if let name = request.operation.name { LabeledContent("软件包", value: name) }
                    if let installed = request.installed { LabeledContent("确认时已安装版本", value: installed.version) }
                    if let available = request.available { LabeledContent("确认时源版本", value: available.version) }
                    if let command = try? request.operation.command() { Text(command).font(AppTypography.secondary.monospaced()).textSelection(.enabled) }
                }
                Section {
                    Text(request.operation.removesPackage ? "卸载可能中断相关服务。依赖求解和拒绝结果由固件返回；不强制删除依赖。" : "包管理器可能同时安装依赖、升级关联组件并运行维护脚本。软件源版本由固件最终决定，无法在手机端承诺无损回滚。")
                    Text("网络中断或超时后不会自动重试。命令退出码、输出和清单重读将分别显示；退出码为 0 不等于服务业务正常。")
                }.font(AppTypography.secondary).foregroundStyle(.secondary)
                Section("HTTP 会话权限") {
                    if let allowed {
                        Label(allowed ? "固定 helper 与 CGI 访问获准" : "账户未获准执行此操作", systemImage: allowed ? "checkmark.shield" : "lock.shield")
                    } else if accessError == nil { ProgressView("检查权限…") }
                    if let accessError { Text(accessError).foregroundStyle(AppPalette.orange) }
                    if !submitted {
                        Button("重新检查权限") { Task { await checkAccess() } }.disabled(store.isMutating)
                    }
                }
                if !submitted {
                    Section {
                        Button(request.operation.title, role: request.operation.removesPackage ? .destructive : nil) {
                            submitted = true
                            Task {
                                do {
                                    taskID = try await store.performPackageOperation(request.operation, installedVersion: request.installed?.version, availableVersion: request.available?.version)
                                } catch { accessError = FriendlyError.message(error) }
                            }
                        }.disabled(allowed != true || store.isMutating || store.isReadingPackages || store.pendingConfiguration != nil || store.packageRecheckRequired)
                            .accessibilityIdentifier("package-confirm-submit")
                    }
                }
                if submitted {
                    if store.isMutating { Section { ProgressView("路由器正在处理…请等待命令返回") } }
                    if let task = taskID.flatMap({ id in store.packageTasks.first { $0.id == id } }) { PackageTaskContent(task: task) }
                }
            }.font(AppTypography.row).appDetailStyle(request.operation.title)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(submitted ? "完成" : "取消") { dismiss() }.disabled(store.isMutating) } }
                .task { await checkAccess() }
        }.tint(AppPalette.accent).interactiveDismissDisabled(store.isMutating)
    }
    private func checkAccess() async {
        allowed = nil; accessError = nil
        do { allowed = try await store.packageOperationAccess(request.operation) }
        catch { accessError = FriendlyError.message(error) }
    }
}

private struct PackageTasksView: View {
    @Environment(RouterStore.self) private var store
    var body: some View {
        List {
            Section { Text("保留当前路由器会话最近 10 个任务。断开连接后清除；运行中不会切换路由器或重复提交。").font(AppTypography.secondary).foregroundStyle(.secondary) }
            ForEach(store.packageTasks) { task in
                NavigationLink {
                    PackageTaskView(id: task.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.operation.title + (task.operation.name.map { " · " + $0 } ?? ""))
                        Text(task.running ? "处理中" : task.uncertain ? "请求结果未确认" : task.result.map { "退出码 \($0.output.exitCode)" } ?? "请求未执行或失败")
                            .font(AppTypography.secondary).foregroundStyle(.secondary)
                        Text(task.startedAt, style: .time).font(AppTypography.metadata)
                    }
                }
            }
            if store.packageTasks.isEmpty { Text("本次会话尚无软件包任务。").foregroundStyle(.secondary) }
        }.appDetailStyle("软件包任务")
    }
}

private struct PackageTaskView: View {
    @Environment(RouterStore.self) private var store
    let id: UUID
    var body: some View {
        List {
            if let task = store.packageTasks.first(where: { $0.id == id }) { PackageTaskContent(task: task) }
            else { Text("此任务已退出当前会话记录。") }
        }.font(AppTypography.row).appDetailStyle("任务结果")
    }
}

private struct PackageTaskContent: View {
    let task: PackageTaskRecord
    var body: some View {
        Section("实际结果") {
            Text(task.operation.title + (task.operation.name.map { " · " + $0 } ?? ""))
            LabeledContent("开始") { Text(task.startedAt, style: .time) }
            if let date = task.completedAt { LabeledContent("返回并重读完成") { Text(date, style: .time) } }
            if task.running { ProgressView("等待请求与清单重读…") }
            if let error = task.error { Text(error).foregroundStyle(AppPalette.orange).textSelection(.enabled) }
            if let result = task.result {
                LabeledContent("退出码", value: String(result.output.exitCode))
                if let command = result.command { Text(command).font(AppTypography.secondary.monospaced()).textSelection(.enabled) }
                NavigationLink("标准输出 · \(result.output.stdout.utf8.count) 字节") { PackageOutputView(title: "标准输出", text: result.output.stdout) }
                NavigationLink("错误输出 · \(result.output.stderr.utf8.count) 字节") { PackageOutputView(title: "错误输出", text: result.output.stderr) }
            }
            if let verification = task.verification { Text(verification).textSelection(.enabled) }
        }
    }
}

private struct PackageOutputView: View {
    let title: String
    let text: String
    @State private var characters = 32_768
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(text.isEmpty ? "此输出为空。" : String(text.prefix(characters))).font(AppTypography.secondary.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if text.count > characters { Button("继续显示后续输出") { characters += 32_768 }.buttonStyle(.bordered) }
            }.padding()
        }.appDetailStyle(title)
    }
}
