import SwiftUI
import OpenWrtKit

struct SQMManagementView: View {
    @Environment(RouterStore.self) private var store
    @State private var runtime: SQMRuntimeSnapshot?
    @State private var kernel: SQMKernelSnapshot?
    @State private var runtimeError: String?
    @State private var kernelError: String?
    @State private var loading = false
    @State private var connection: UUID?
    @State private var runtimeRequest = UUID()
    @State private var kernelRequest = UUID()
    @State private var kernelLoading = false

    private var queues: [ConfigurationSection] { runtime?.configuration?.sections.filter { $0.type == "queue" } ?? [] }

    var body: some View {
        AppPage(title: "", subtitle: nil) {
            if loading { ProgressView("正在读取 SQM 配置、脚本和内核队列…") }
            if let runtimeError {
                AppSection(title: "SQM 读取失败") {
                    AppGroup {
                        Text(runtimeError).foregroundStyle(AppPalette.red).padding(12)
                        Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }
                    }
                }
            }
            if let runtime {
                AppSection(title: "原生管理") {
                    AppGroup {
                        NavigationLink { NativeConfigurationView(schema: .sqm) } label: {
                            AppRow(title: "队列与链路层配置", detail: "实例、实际安装的 qdisc、脚本与硬件设备", symbol: "slider.horizontal.3", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("sqm-configuration")
                        if let service = runtime.startup {
                            AppDivider()
                            NavigationLink { ServiceDetailView(name: service.name) } label: {
                                AppRow(title: "SQM 系统服务", detail: "服务启动项不代表队列已建立", symbol: "gearshape",
                                       value: service.enabled.map { $0 ? "开机启用" : "开机关闭" } ?? "状态未知", chevron: true)
                            }.buttonStyle(.plain).accessibilityIdentifier("sqm-service")
                        } else {
                            AppDivider()
                            AppRow(title: "SQM 系统服务", detail: runtime.issues["启动项"] ?? "固件没有报告 sqm 启动项。", value: "未确认")
                        }
                    }
                }

                AppSection(title: "配置实例", note: "实例来自路由器 sqm UCI 配置。enabled 表示配置意图，实际生效情况请看下方 tc 内核队列。") {
                    AppGroup {
                        if let configuration = runtime.configuration {
                            if queues.isEmpty { Text("固件已返回配置，当前没有 queue 类型实例。").font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(12) }
                            ForEach(queues) { queue in
                                NavigationLink { SQMQueueDetailView(section: queue, kernel: kernel, kernelError: kernelError, kernelLoading: kernelLoading) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        AppRow(title: queue.values["interface"]?.stringValue ?? queue.id,
                                               value: queue.values["enabled"]?.stringValue == "1" ? "已启用配置" : queue.values["enabled"]?.stringValue == "0" ? "已停用配置" : "启用状态未设置")
                                        Text("\(queue.values["qdisc"]?.stringValue ?? "队列规则未设置") · \(queue.values["script"]?.stringValue ?? "脚本未设置")")
                                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(.horizontal, 12).padding(.bottom, 10)
                                    }
                                }.buttonStyle(.plain).accessibilityIdentifier("sqm-queue-\(queue.id)")
                                if queue.id != queues.last?.id { AppDivider() }
                            }
                        } else {
                            Text(runtime.issues["队列配置"] ?? "未能读取 sqm 配置。").font(AppTypography.secondary).foregroundStyle(AppPalette.orange).padding(12)
                        }
                    }
                }

                AppSection(title: "固件能力") {
                    AppGroup {
                        capabilityRow("可用队列规则", value: runtime.qdiscs.map { "\($0.count) 项" }, detail: runtime.qdiscs?.joined(separator: "、"), issue: runtime.issues["可用队列规则"])
                        AppDivider()
                        capabilityRow("SQM 队列脚本", value: runtime.scripts.map { "\($0.count) 项" }, detail: runtime.scripts?.joined(separator: "、"), issue: runtime.issues["可用脚本"])
                        AppDivider()
                        capabilityRow("网络设备", value: runtime.devices.map { "\($0.count) 项" },
                                      detail: runtime.devices?.map { "\($0.name)：\($0.up.map { $0 ? "启用" : "未启用" } ?? "状态未报告")" }.joined(separator: " · "),
                                      issue: runtime.issues["网络设备"])
                        AppDivider()
                        AppRow(title: "读取时间", value: runtime.readAt.formatted(date: .abbreviated, time: .standard))
                    }
                }
            }

            AppSection(title: "内核实际队列与统计", note: "读取路由器 tc 的队列清单与统计，包含固件实际创建的 IFB 设备。内核返回空清单才表示本次查询没有 qdisc；失败不会显示成 0。") {
                AppGroup {
                    if kernelLoading { ProgressView("正在读取内核队列…").padding(12) }
                    if let kernelError {
                        Text(kernelError).font(AppTypography.secondary).foregroundStyle(AppPalette.red).textSelection(.enabled).padding(12)
                    } else if let kernel {
                        if let compatibilityNote {
                            Text(compatibilityNote).font(AppTypography.secondary).foregroundStyle(AppPalette.orange).padding(12)
                        }
                        if let disciplines = kernel.disciplines {
                            if disciplines.isEmpty {
                                Text("tc 成功返回空队列清单；当前没有已挂载 qdisc。").font(AppTypography.secondary).foregroundStyle(AppPalette.orange).padding(12)
                            }
                            ForEach(disciplines) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    AppRow(title: item.device, detail: "句柄 \(item.handle)" + (item.root == true ? " · 根队列" : item.parent.map { " · 父级 \($0)" } ?? ""), value: item.kind)
                                    if !item.counters.isEmpty {
                                        Text(item.counters.keys.sorted().map { "\($0)：\(item.counters[$0]!)" }.joined(separator: " · "))
                                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(.horizontal, 12)
                                    }
                                    NavigationLink { SQMKernelDetailView(title: item.device + " · " + item.kind, text: item.details) } label: {
                                        AppRow(title: "查看内核返回详情", symbol: "doc.text.magnifyingglass", chevron: true)
                                    }.buttonStyle(.plain)
                                }.padding(.vertical, 6)
                                if item.id != disciplines.last?.id { AppDivider() }
                            }
                        } else {
                            NavigationLink { SQMKernelDetailView(title: "tc 队列列表", text: kernel.output.stdout) } label: {
                                AppRow(title: "查看 tc 实际文本输出", detail: "当前 tc 不支持 JSON，未猜测结构化计数", chevron: true)
                            }.buttonStyle(.plain)
                        }
                        AppRow(title: "读取时间", value: kernel.readAt.formatted(date: .abbreviated, time: .standard))
                    } else {
                        Text("尚未读取内核队列。").font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(12)
                    }
                    Button("读取实际队列", systemImage: "arrow.clockwise") { Task { await loadKernel() } }
                        .disabled(loading || kernelLoading || store.isMutating || store.pendingConfiguration != nil)
                }
            }
        }
        .appDetailStyle("SQM 队列管理")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
            }
        }
        .task(id: store.connectionID) {
            if connection != store.connectionID { connection = store.connectionID; runtime = nil; kernel = nil }
            await load()
        }
    }

    @ViewBuilder private func capabilityRow(_ title: String, value: String?, detail: String?, issue: String?) -> some View {
        if let issue {
            VStack(alignment: .leading, spacing: 4) {
                AppRow(title: title, value: "读取失败")
                Text(issue).font(AppTypography.secondary).foregroundStyle(AppPalette.red).textSelection(.enabled).padding(.horizontal, 12)
            }.padding(.vertical, 8)
        } else {
            AppRow(title: title, detail: detail ?? "固件未返回此能力清单。", value: value ?? "未报告")
        }
    }

    private var compatibilityNote: String? {
        guard let kernel else { return nil }
        return kernel.compatibilityNote
    }

    private func load() async {
        let generation = store.connectionID, request = UUID()
        runtimeRequest = request
        loading = true; runtime = nil; runtimeError = nil
        defer { if generation == store.connectionID, request == runtimeRequest { loading = false } }
        do {
            let value = try await store.sqmRuntime()
            guard generation == store.connectionID, request == runtimeRequest, !Task.isCancelled else { return }
            runtime = value
        } catch {
            guard generation == store.connectionID, request == runtimeRequest, !Task.isCancelled else { return }
            runtime = nil; runtimeError = FriendlyError.message(error)
        }
        await loadKernel()
    }

    private func loadKernel() async {
        let generation = store.connectionID, request = UUID()
        kernelRequest = request; kernelLoading = true; kernel = nil; kernelError = nil
        defer { if generation == store.connectionID, request == kernelRequest { kernelLoading = false } }
        do {
            let value = try await store.sqmKernel()
            guard generation == store.connectionID, request == kernelRequest, !Task.isCancelled else { return }
            kernel = value
        } catch {
            guard generation == store.connectionID, request == kernelRequest, !Task.isCancelled else { return }
            kernelError = FriendlyError.message(error)
        }
    }
}

private struct SQMQueueDetailView: View {
    let section: ConfigurationSection
    let kernel: SQMKernelSnapshot?
    let kernelError: String?
    let kernelLoading: Bool
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "当前配置") {
                AppGroup {
                    AppRow(title: "状态", value: section.values["enabled"]?.stringValue == "1" ? "已启用配置" : section.values["enabled"]?.stringValue == "0" ? "已停用配置" : "未设置")
                    AppDivider()
                    AppRow(title: "网络设备", value: section.values["interface"]?.stringValue ?? "未设置")
                    AppDivider()
                    AppRow(title: "下载整形", value: section.values["download"]?.stringValue.map { $0 + " kbit/s" } ?? "固件默认")
                    AppDivider()
                    AppRow(title: "上传整形", value: section.values["upload"]?.stringValue.map { $0 + " kbit/s" } ?? "固件默认")
                    AppDivider()
                    AppRow(title: "队列规则", value: section.values["qdisc"]?.stringValue ?? "未设置")
                    AppDivider()
                    AppRow(title: "队列脚本", value: section.values["script"]?.stringValue ?? "未设置")
                    if let script = section.values["script"]?.stringValue, !script.isEmpty {
                        AppDivider()
                        NavigationLink { SQMTextView(request: .scriptHelp(script)) } label: {
                            AppRow(title: "读取脚本说明", symbol: "doc.text", chevron: true)
                        }.buttonStyle(.plain)
                    }
                }
            }
            AppSection(title: "实际内核队列", note: "展示本次 tc 返回的完整清单，包括固件实际创建的 IFB 设备；不根据接口名猜测队列归属。") {
                AppGroup {
                    if kernelLoading {
                        ProgressView("正在读取 tc 队列…").padding(12)
                    } else if let kernelError {
                        Text(kernelError).font(AppTypography.secondary).foregroundStyle(AppPalette.red).textSelection(.enabled).padding(12)
                    } else if let kernel, let disciplines = kernel.disciplines {
                        let configuredInterface = section.values["interface"]?.stringValue
                        if disciplines.isEmpty {
                            Text("tc 成功返回空队列清单；当前没有已挂载 qdisc。").font(AppTypography.secondary).foregroundStyle(AppPalette.orange).padding(12)
                        }
                        ForEach(disciplines) { item in
                            AppRow(title: item.device + (item.device == configuredInterface ? " · 配置接口" : ""),
                                   detail: item.counters.keys.sorted().map { "\($0)：\(item.counters[$0]!)" }.joined(separator: " · "),
                                   value: item.kind + " · \(item.handle)")
                            if item.id != disciplines.last?.id { AppDivider() }
                        }
                    } else if let kernel, kernel.disciplines == nil {
                        NavigationLink { SQMKernelDetailView(title: "tc 队列列表", text: kernel.output.stdout) } label: {
                            AppRow(title: "查看 tc 文本队列数据", chevron: true)
                        }.buttonStyle(.plain)
                    } else {
                        Text("尚未读取实际队列。").font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(12)
                    }
                    if let interface = section.values["interface"]?.stringValue, WakeOnLANTarget.validInterface(interface) {
                        ForEach([SQMReadRequest.startLog(interface), SQMReadRequest.stopLog(interface)], id: \.title) { request in
                            NavigationLink { SQMTextView(request: request) } label: { AppRow(title: request.title, symbol: "doc.text", chevron: true) }
                                .buttonStyle(.plain)
                        }
                    } else {
                        Text("配置未提供有效设备名称，无法定位日志。").font(AppTypography.secondary).foregroundStyle(AppPalette.orange).padding(12)
                    }
                    if let kernel {
                        AppRow(title: "内核读取时间", value: kernel.readAt.formatted(date: .abbreviated, time: .standard))
                    }
                }
            }
            AppSection(title: "完整配置字段") {
                AppGroup { NavigationLink { NativeConfigurationView(schema: .sqm) } label: { AppRow(title: "编辑此路由器的 SQM 配置", symbol: "slider.horizontal.3", chevron: true) }.buttonStyle(.plain) }
            }
        }.appDetailStyle(section.values["interface"]?.stringValue ?? "SQM 队列")
    }
}

private struct SQMTextView: View {
    @Environment(RouterStore.self) private var store
    let request: SQMReadRequest
    @State private var output: String?
    @State private var error: String?
    @State private var loading = false
    @State private var requestID = UUID()
    var body: some View {
        List {
            Section {
                if loading { ProgressView("正在从路由器读取…") }
                if let error { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) }
                Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
            }
            if let output {
                Section("路由器原始返回") {
                    Text(output.isEmpty ? "路由器返回的文件内容为空。" : output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle(request.title)
            .task(id: store.connectionID) { output = nil; await load() }
    }
    private func load() async {
        let generation = store.connectionID, id = UUID()
        requestID = id; loading = true; output = nil; error = nil
        defer { if generation == store.connectionID, requestID == id { loading = false } }
        do {
            let value = try await store.sqmText(request)
            guard generation == store.connectionID, requestID == id, !Task.isCancelled else { return }
            output = value
        } catch {
            guard generation == store.connectionID, requestID == id, !Task.isCancelled else { return }
            self.error = FriendlyError.message(error)
        }
    }
}

private struct SQMKernelDetailView: View {
    let title: String
    let text: String
    var body: some View {
        List { Section("路由器 tc 返回") { Text(text.isEmpty ? "tc 返回内容为空。" : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
            .font(AppTypography.row).appDetailStyle(title)
    }
}
