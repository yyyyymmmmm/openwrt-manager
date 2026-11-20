import SwiftUI
import OpenWrtKit

/// The native file manager (phase 3): browsing over the ubus file plane.
/// Saving an edit is a verified write behind an explicit confirmation —
/// the same discipline as every other write in the app.
struct FileManagerView: View {
    @Environment(RouterStore.self) private var store
    @State private var path = "/etc/config"
    @State private var state: LoadState<[FileEntry]> = .loading
    @State private var removeTarget: FileEntry?
    @State private var actionError: String?

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
                        } else {
                            NavigationLink {
                                FileEditorView(directory: path, entry: entry)
                            } label: {
                                row(for: entry)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("删除", role: .destructive) { removeTarget = entry }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("文件管理")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) { await load() }
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
}

/// View and edit one text file. Save = confirmation + verified write.
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

    private var filePath: String {
        directory == "/" ? "/\(entry.name)" : "\(directory)/\(entry.name)"
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("正在读取文件…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded:
                VStack(spacing: AppSpacing.sm) {
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
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { confirmingSave = true }
                    .disabled(draft == original)
            }
        }
        .task { await load() }
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
