import SwiftUI
import UniformTypeIdentifiers
import OpenWrtKit

/// The native file manager (phase 3, completed in package D):
/// browsing over the ubus file plane, plus the operations the audit
/// found missing (F8) — download to this device and share, upload,
/// new folder/file, rename, and empty-directory removal. Saving an
/// edit is a verified write behind an explicit confirmation — the
/// same discipline as every other write in the app. Directory
/// creation/rename/removal go through the kit's fixed-command exec
/// plane and are verified by re-listing, never assumed.
struct FileManagerView: View {
    @Environment(RouterStore.self) private var store
    @State private var path = "/etc/config"
    @State private var state: LoadState<[FileEntry]> = .loading
    @State private var removeTarget: FileEntry?
    @State private var removeDirectoryTarget: FileEntry?
    @State private var actionError: String?
    @State private var showingImporter = false
    @State private var isTransferring = false
    @State private var downloadedFile: DownloadedFile?
    @State private var prompt: NamePrompt?
    /// Batch-3-locked operation groups, from the session-access
    /// precheck (permission audit #15–#17): the fixed-command execs
    /// (mkdir/mv/rmdir) and arbitrary-path writes are granted to no
    /// login session on stock firmware, so those entries are greyed
    /// out with an explanation instead of failing after the fact.
    @State private var directoryOpsDenied = false
    @State private var writeDenied = false

    private struct DownloadedFile: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private enum NamePrompt: Identifiable {
        case newFolder, newFile, rename(FileEntry)
        var id: String {
            switch self {
            case .newFolder: return "newFolder"
            case .newFile: return "newFile"
            case .rename(let entry): return "rename-\(entry.name)"
            }
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: AppSpacing.sm) {
                    Button {
                        navigateUp()
                    } label: {
                        Image(systemName: "arrow.up.circle")
                    }
                    .disabled(path == "/")
                    Text(path).font(AppTypography.rowTitle.monospaced()).lineLimit(1)
                }
            }
            if directoryOpsDenied || writeDenied {
                Section {
                    Label("这台固件未向 App 登录会话开放新建文件夹、重命名、删除空目录与向任意路径写入（rpcd 未授权），相关操作已禁用；需要在路由器上补授权后才能使用。浏览与已授权文件的读取不受影响。", systemImage: "lock")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
            }
            if isTransferring {
                HStack { ProgressView(); Text("正在传输文件…") }
            }
            if let actionError {
                ErrorStateView(message: actionError)
            }
            switch state {
            case .loading:
                ProgressView("正在读取目录…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let entries):
                if entries.isEmpty {
                    EmptyStateView(title: "空目录", message: "此目录没有条目。", symbol: "folder")
                } else {
                    ForEach(entries) { entry in
                        if entry.isDirectory {
                            Button {
                                path = join(path, entry.name)
                                Task { await load() }
                            } label: {
                                row(for: entry)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("删除", role: .destructive) { removeDirectoryTarget = entry }
                                    .disabled(directoryOpsDenied)
                                Button("重命名") { renameName = entry.name; prompt = .rename(entry) }
                                    .disabled(directoryOpsDenied)
                            }
                            .contextMenu {
                                Button("重命名") { renameName = entry.name; prompt = .rename(entry) }
                                    .disabled(directoryOpsDenied)
                                Button("删除空目录", role: .destructive) { removeDirectoryTarget = entry }
                                    .disabled(directoryOpsDenied)
                            }
                        } else {
                            NavigationLink {
                                FileEditorView(directory: path, entry: entry)
                            } label: {
                                row(for: entry)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("删除", role: .destructive) { removeTarget = entry }
                                Button("重命名") { renameName = entry.name; prompt = .rename(entry) }
                                    .disabled(directoryOpsDenied)
                                Button("下载") { Task { await download(entry) } }
                            }
                            .contextMenu {
                                Button("下载并分享") { Task { await download(entry) } }
                                Button("重命名") { renameName = entry.name; prompt = .rename(entry) }
                                    .disabled(directoryOpsDenied)
                                Button("删除", role: .destructive) { removeTarget = entry }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("文件管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("上传文件", systemImage: "square.and.arrow.up")
                    }
                    .disabled(writeDenied)
                    Button {
                        prompt = .newFolder
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                    .disabled(directoryOpsDenied)
                    Button {
                        prompt = .newFile
                    } label: {
                        Label("新建文件", systemImage: "doc.badge.plus")
                    }
                    .disabled(writeDenied)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建或上传")
            }
        }
        .task(id: path) { await load() }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                Task { await upload(urls) }
            }
        }
        .sheet(item: $downloadedFile) { file in
            NavigationStack {
                VStack(spacing: AppSpacing.md) {
                    Image(systemName: "doc.fill").font(.largeTitle).foregroundStyle(AppPalette.accent)
                    Text(file.url.lastPathComponent).font(AppTypography.rowTitle).lineLimit(2)
                    Text("文件已下载到本机，可保存到「文件」或通过其他 App 分享。")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        .multilineTextAlignment(.center)
                    ShareLink(item: file.url) {
                        Label("分享文件", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(AppPrimaryButtonStyle())
                }
                .padding(AppSpacing.md)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { downloadedFile = nil }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("新建文件夹", isPresented: promptBinding(for: .newFolder)) {
            TextField("名称", text: $newFolderName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) { prompt = nil }
            Button("创建") {
                let name = newFolderName
                newFolderName = ""
                prompt = nil
                Task { await applyNamePrompt(.newFolder, name: name) }
            }
        } message: {
            Text("名称不能包含 /，也不能是 . 或 ..。")
        }
        .alert("新建文件", isPresented: promptBinding(for: .newFile)) {
            TextField("名称", text: $newFileName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) { prompt = nil }
            Button("创建") {
                let name = newFileName
                newFileName = ""
                prompt = nil
                Task { await applyNamePrompt(.newFile, name: name) }
            }
        } message: {
            Text("名称不能包含 /，也不能是 . 或 ..。")
        }
        .alert("重命名", isPresented: renamePresented) {
            TextField("名称", text: $renameName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) { prompt = nil }
            Button("确定") {
                let active = prompt
                let name = renameName
                renameName = ""
                prompt = nil
                Task { await applyNamePrompt(active, name: name) }
            }
        } message: {
            if case .rename(let entry) = prompt {
                Text("原名称：\(entry.name)。名称不能包含 /，也不能是 . 或 ..。")
            }
        }
        .confirmationDialog(
            removeTarget.map { "删除「\($0.name)」？" } ?? "",
            isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = removeTarget { Task { await remove(target) } }
                removeTarget = nil
            }
            Button("取消", role: .cancel) { removeTarget = nil }
        } message: {
            Text("删除后无法从 App 内恢复。")
        }
        .confirmationDialog(
            removeDirectoryTarget.map { "删除空目录「\($0.name)」？" } ?? "",
            isPresented: Binding(get: { removeDirectoryTarget != nil }, set: { if !$0 { removeDirectoryTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = removeDirectoryTarget { Task { await removeDirectory(target) } }
                removeDirectoryTarget = nil
            }
            Button("取消", role: .cancel) { removeDirectoryTarget = nil }
        } message: {
            Text("只删除空目录；目录非空时路由器会拒绝，内容不会受影响。")
        }
    }

    @State private var newFolderName = ""
    @State private var newFileName = ""
    @State private var renameName = ""

    private func promptBinding(for kind: NamePrompt) -> Binding<Bool> {
        Binding(get: {
            switch (prompt, kind) {
            case (.newFolder, .newFolder), (.newFile, .newFile): return true
            default: return false
            }
        }, set: { if !$0 { prompt = nil } })
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: {
            if case .rename = prompt { return true }
            return false
        }, set: { if !$0 { prompt = nil } })
    }

    private func row(for entry: FileEntry) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(AppPalette.accent)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(entry.name).font(AppTypography.rowTitle)
                Text(detailText(for: entry)).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
        }
    }

    private func detailText(for entry: FileEntry) -> String {
        var parts: [String] = []
        if let size = entry.size, !entry.isDirectory { parts.append(FormatHelpers.bytes(size)) }
        if let modified = entry.modifiedAt {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? (entry.isDirectory ? "目录" : "文件") : parts.joined(separator: " · ")
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    private func navigateUp() {
        guard path != "/" else { return }
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        path = parent.isEmpty ? "/" : "/" + parent
    }

    private func load() async {
        guard let files = store.fileClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        do { state = .loaded(try await files.list(path: path)) }
        catch { state = .failed(FriendlyError.message(error)) }
        await refreshAccessGates()
    }

    /// Session-access precheck for the batch-3-locked operations.
    /// The three directory commands share one fate in every measured
    /// acl.d (none granted), so one probe stands for the group; the
    /// write probe targets a child-shaped path so directory-prefix
    /// grants ("/tmp/*" style) answer truthfully.
    private func refreshAccessGates() async {
        guard let client = store.readClient else { return }
        directoryOpsDenied = !(await client.sessionAccess(scope: "file", object: "/bin/mkdir", function: "exec"))
        let probe = path == "/" ? "/.zirox-write-probe" : "\(path)/.zirox-write-probe"
        writeDenied = !(await client.sessionAccess(scope: "file", object: probe, function: "write"))
    }

    private func remove(_ entry: FileEntry) async {
        guard let files = store.fileClient else { return }
        do {
            try await files.remove(path: join(path, entry.name))
            actionError = nil
            await load()
        } catch {
            actionError = FriendlyError.message(error)
        }
    }

    private func removeDirectory(_ entry: FileEntry) async {
        guard let files = store.fileClient else { return }
        do {
            try await files.removeDirectory(path: join(path, entry.name))
            actionError = nil
            await load()
        } catch {
            actionError = FriendlyError.message(error)
        }
    }

    /// Downloads one file into the app's temporary store and offers
    /// it through the system share sheet: the Files-app save and
    /// every share target come from the platform, not a custom UI.
    private func download(_ entry: FileEntry) async {
        guard let files = store.fileClient else { return }
        isTransferring = true
        defer { isTransferring = false }
        do {
            let base64 = try await files.readBase64(path: join(path, entry.name))
            guard let data = Data(base64Encoded: base64) else {
                actionError = L10n.string("下载的数据无法解析。")
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
            try data.write(to: url, options: .atomic)
            actionError = nil
            downloadedFile = DownloadedFile(url: url)
        } catch {
            actionError = FriendlyError.message(error)
        }
    }

    /// Uploads picked files into the current directory with the
    /// kit's chunked, size-verified binary write.
    private func upload(_ urls: [URL]) async {
        guard let files = store.fileClient else { return }
        isTransferring = true
        defer { isTransferring = false }
        do {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                try await files.writeDataVerified(path: join(path, url.lastPathComponent), data: data)
            }
            actionError = nil
            await load()
        } catch {
            actionError = FriendlyError.message(error)
        }
    }

    private func applyNamePrompt(_ active: NamePrompt?, name rawName: String) async {
        guard let active, let files = store.fileClient else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            actionError = L10n.string("名称不合法：不能为空，也不能包含 / 或为 . 与 ..。")
            return
        }
        do {
            switch active {
            case .newFolder:
                try await files.makeDirectory(path: join(path, name))
            case .newFile:
                try await files.writeTextVerified(path: join(path, name), content: "")
            case .rename(let entry):
                try await files.rename(from: join(path, entry.name), to: join(path, name))
            }
            actionError = nil
            await load()
        } catch {
            actionError = FriendlyError.message(error)
        }
    }
}

/// View and edit one text file. Save = confirmation + verified write.
/// Files above the small-text ceiling are not loaded into the editor
/// at all — a truncated edit would corrupt them; the view says so
/// and points at download instead (package D).
struct FileEditorView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let directory: String
    let entry: FileEntry
    @State private var state: LoadState<String> = .loading
    @State private var draft = ""
    @State private var original = ""
    @State private var confirmingSave = false
    @State private var saveResult: String?
    /// Write access for this exact path, from the session-access
    /// precheck: without it the save action is disabled up front
    /// instead of failing after the edit.
    @State private var writeDenied = false

    /// The in-app editor's ceiling: config-sized text only.
    static let editableCeiling: Int64 = 256 * 1024

    private var filePath: String {
        directory == "/" ? "/\(entry.name)" : "\(directory)/\(entry.name)"
    }

    private var isTooLarge: Bool {
        (entry.size ?? 0) > Self.editableCeiling
    }

    var body: some View {
        Group {
            if isTooLarge {
                EmptyStateView(
                    title: "文件较大，不在 App 内编辑",
                    message: "此文件 \(FormatHelpers.bytes(entry.size ?? 0))，超过内置编辑上限（\(FormatHelpers.bytes(Self.editableCeiling))）。请从文件列表下载到本机查看或编辑。",
                    symbol: "doc.badge.gearshape")
                    .padding(AppSpacing.md)
            } else {
                switch state {
                case .loading:
                    ProgressView("正在读取文件…")
                case .failed(let message):
                    ErrorStateView(message: message) { Task { await load() } }
                case .loaded:
                    VStack(spacing: AppSpacing.sm) {
                        if writeDenied {
                            Label("这台固件未向 App 会话开放此路径的写入（rpcd 未授权），只能查看，不能保存修改。", systemImage: "lock")
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                        if let saveResult {
                            Text(saveResult).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                        TextEditor(text: $draft)
                            .font(AppTypography.metadata.monospaced())
                            .padding(AppSpacing.sm)
                    }
                    .padding(AppSpacing.sm)
                }
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { confirmingSave = true }
                    .disabled(isTooLarge || writeDenied || draft == original)
            }
        }
        .task { if !isTooLarge { await load() } }
        .confirmationDialog("保存对「\(entry.name)」的修改？", isPresented: $confirmingSave, titleVisibility: .visible) {
            Button("保存并验证") { Task { await save() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保存后会立即回读文件核对内容一致。")
        }
    }

    private func load() async {
        guard let files = store.fileClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        // File reads are authorized per path (permission audit #15):
        // most paths on stock firmware are not granted, and the page
        // says exactly that instead of a generic permission failure.
        if let client = store.readClient {
            let readable = await client.sessionAccess(scope: "file", object: filePath, function: "read")
            guard readable else {
                state = .failed(L10n.string("路由器未授权读取此文件：这台固件没有向 App 会话开放该路径的读取（rpcd ACL 未包含），需要在路由器上补授权后才能打开。"))
                return
            }
            writeDenied = !(await client.sessionAccess(scope: "file", object: filePath, function: "write"))
        }
        do {
            let text = try await files.readText(path: filePath)
            original = text
            draft = text
            state = .loaded(text)
        } catch { state = .failed(FriendlyError.message(error)) }
    }

    private func save() async {
        guard let files = store.fileClient else { return }
        do {
            try await files.writeTextVerified(path: filePath, content: draft)
            original = draft
            saveResult = "已保存并回读验证一致。"
        } catch {
            saveResult = FriendlyError.message(error)
        }
    }
}
