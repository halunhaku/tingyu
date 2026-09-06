import SwiftUI
import SwiftData
#if canImport(AppKit)
import AppKit
#endif

public struct SourceManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var sources: [MusicSource]

    @State private var showingAddWebDAV = false
    @State private var showingLocalFolderImporter = false
    @State private var showingAddQuark = false
    @State private var showingAISettings = false
    @State private var isScanning = false
    @State private var scanStatusMessage = ""
    @State private var sourceToDelete: MusicSource? = nil
    @State private var showingDeleteConfirm = false
    @Bindable var cloudSync = CloudSyncManager.shared

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("已添加的音乐来源") {
                    if sources.isEmpty {
                        Text("暂未添加音乐来源")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sources) { source in
                            HStack(spacing: 12) {
                                Image(systemName: source.kind == .quark ? "bolt.cloud.fill" : (source.kind == .webdav ? "cloud.fill" : "folder.fill"))
                                    .font(.title3)
                                    .foregroundStyle(source.kind == .quark ? Color.green : (source.kind == .webdav ? Color.blue : Color.orange))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name)
                                        .font(.headline)
                                    Text(source.syncStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                HStack(spacing: 16) {
                                    Button {
                                        Task {
                                            await rescanSource(source)
                                        }
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("重新扫描曲库")

                                    Button(role: .destructive) {
                                        sourceToDelete = source
                                        showingDeleteConfirm = true
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(Color.red.opacity(0.85))
                                    }
                                    .buttonStyle(.plain)
                                    .help("删除此音乐来源")
                                }
                            }
                        }
                        .onDelete(perform: deleteSources)
                    }
                }

                Section("添加新来源") {
                    Button {
                        #if os(macOS)
                        selectLocalFolderMacOS()
                        #else
                        showingLocalFolderImporter = true
                        #endif
                    } label: {
                        Label("添加本地音乐文件夹", systemImage: "folder.badge.plus")
                    }

                    Button {
                        showingAddWebDAV = true
                    } label: {
                        Label("添加 WebDAV 私人云", systemImage: "cloud.badge.plus")
                    }

                    Button {
                        showingAddQuark = true
                    } label: {
                        Label("添加夸克网盘（支持扫码）", systemImage: "bolt.cloud.fill")
                            .foregroundStyle(Color.green)
                    }
                }

                Section("iCloud 云同步与多端互通") {
                    Toggle("启用 iCloud 曲库同步", isOn: $cloudSync.isCloudSyncEnabled)

                    HStack(spacing: 8) {
                        Image(systemName: cloudSync.isCloudSyncEnabled ? "icloud.fill" : "icloud.slash")
                            .foregroundStyle(cloudSync.isCloudSyncEnabled ? Color.blue : Color.secondary)
                        Text(cloudSync.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("开启后，您在 macOS 与 iOS 设备上的曲库索引、收藏标记和播放列表将自动在您的私人 iCloud 容器间同步。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("AI 智能大模型识别") {
                    Button {
                        showingAISettings = true
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundStyle(Color.purple)
                            Text(AIService.shared.isEnabled ? "AI 智能识别已启用 (点击管理)" : "配置 AI 大模型识别")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if isScanning {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(scanStatusMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button("停止") {
                                isScanning = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .navigationTitle("音乐来源管理")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingAddWebDAV) {
                AddWebDAVSheet()
            }
            .sheet(isPresented: $showingAddQuark) {
                AddQuarkSheet()
            }
            .sheet(isPresented: $showingAISettings) {
                AISettingsView()
            }
            #if os(iOS)
            .fileImporter(
                isPresented: $showingLocalFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let folderUrl = urls.first {
                        addLocalFolder(url: folderUrl)
                    }
                case .failure(let error):
                    print("Folder import failed: \(error)")
                }
            }
            #endif
            .onAppear {
                LegacyCacheMigrator.migrateIfNeeded(modelContext: modelContext, sources: sources)
            }
            .confirmationDialog(
                "确定要删除「\(sourceToDelete?.name ?? "此音源")」吗？",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除来源并移除曲目", role: .destructive) {
                    if let target = sourceToDelete {
                        deleteSourceCompletely(target)
                    }
                }
                Button("取消", role: .cancel) {
                    sourceToDelete = nil
                }
            } message: {
                Text("删除后，该来源在本地的所有曲目索引与已保存的密码凭据将被彻底移除。")
            }
        }
    }

    #if os(macOS)
    private func selectLocalFolderMacOS() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择音乐文件夹"

        if panel.runModal() == .OK, let url = panel.url {
            addLocalFolder(url: url)
        }
    }
    #endif

    private func addLocalFolder(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let sourceName = url.lastPathComponent
        let bookmark = try? LocalLibraryScanner.shared.createBookmark(for: url)

        let source = MusicSource(
            name: sourceName,
            kind: .local,
            localBookmarkData: bookmark,
            localFolderPath: url.path,
            syncStatus: "正在扫描..."
        )
        modelContext.insert(source)

        Task {
            await rescanSource(source)
        }
    }

    private func rescanSource(_ source: MusicSource) async {
        isScanning = true
        scanStatusMessage = "正在扫描 \(source.name)..."
        defer {
            isScanning = false
        }

        // Stop player if playing a track from this source to avoid reading deleted object
        if AudioPlayerService.shared.currentTrack?.sourceId == source.id {
            AudioPlayerService.shared.stop()
        }

        if source.kind == .local {
            guard let bookmark = source.localBookmarkData,
                  let folderUrl = try? LocalLibraryScanner.shared.resolveBookmark(data: bookmark) else {
                source.syncStatus = "书签已失效"
                return
            }

            let tracks = await LocalLibraryScanner.shared.scanFolder(at: folderUrl, sourceId: source.id) { count, name in
                Task { @MainActor in
                    self.scanStatusMessage = "扫描中 (\(count)): \(name)"
                }
            }

            LibrarySync.merge(scanned: tracks, sourceId: source.id, context: modelContext)
            source.trackCount = tracks.count
            source.syncStatus = "已同步 \(tracks.count) 首"
            source.lastSyncedAt = Date()
        } else if source.kind == .webdav {
            guard let urlString = source.webdavUrl,
                  let url = URL(string: urlString),
                  let username = source.webdavUsername,
                  let password = KeychainService.shared.get(for: username) else {
                source.syncStatus = "凭据丢失"
                return
            }

            do {
                let tracks = try await WebDAVClient.shared.scan(rootUrl: url, sourceId: source.id, username: username, password: password) { count, name in
                    Task { @MainActor in
                        self.scanStatusMessage = "WebDAV 扫描 (\(count)): \(name)"
                    }
                }

                if !tracks.isEmpty {
                    LibrarySync.merge(scanned: tracks, sourceId: source.id, context: modelContext)
                    source.trackCount = tracks.count
                    source.syncStatus = "已同步 \(tracks.count) 首"
                } else {
                    source.syncStatus = "未在目录中找到音频文件"
                }
                source.lastSyncedAt = Date()
            } catch {
                source.syncStatus = "同步失败: \(error.localizedDescription)"
            }
        } else if source.kind == .quark {
            guard let folderFid = source.quarkFolderFid,
                  let cookie = QuarkCookieStore.load(sourceId: source.id) else {
                source.syncStatus = "夸克凭据已失效"
                return
            }

            do {
                let tracks = try await QuarkDriveClient.shared.scan(
                    folderFid: folderFid,
                    sourceId: source.id,
                    cookie: cookie
                ) { count, name in
                    Task { @MainActor in
                        self.scanStatusMessage = "夸克扫描 (\(count)): \(name)"
                    }
                }

                if !tracks.isEmpty {
                    LibrarySync.merge(scanned: tracks, sourceId: source.id, context: modelContext)
                    source.trackCount = tracks.count
                    source.syncStatus = "已同步 \(tracks.count) 首"
                } else {
                    source.syncStatus = "未在选定目录找到音频文件"
                }
                source.lastSyncedAt = Date()
            } catch {
                source.syncStatus = "同步失败: \(error.localizedDescription)"
            }
        }

        try? modelContext.save()
    }

    private func deleteSources(at offsets: IndexSet) {
        for index in offsets {
            let source = sources[index]
            deleteSourceCompletely(source)
        }
    }

    private func deleteSourceCompletely(_ source: MusicSource) {
        let sourceId = source.id
        if AudioPlayerService.shared.currentTrack?.sourceId == sourceId {
            AudioPlayerService.shared.stop()
        }


        // 1. Delete all tracks belonging to this source
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.sourceId == sourceId })
        if let tracks = try? modelContext.fetch(descriptor) {
            for track in tracks {
                modelContext.delete(track)
            }
        }

        // 2. Delete credentials from Keychain
        if source.kind == .webdav, let user = source.webdavUsername {
            try? KeychainService.shared.delete(for: user)
        } else if source.kind == .quark {
            QuarkCookieStore.delete(sourceId: source.id)
        }

        // 3. Delete source itself
        modelContext.delete(source)
        try? modelContext.save()
        sourceToDelete = nil
    }
}

public struct AddWebDAVSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var serverUrl: String = "https://"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isTesting = false
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("连接信息") {
                    TextField("来源名称（如：家里群晖 NAS）", text: $name)
                    TextField("WebDAV 根地址 (URL)", text: $serverUrl)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("用户名", text: $username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("应用专用密码", text: $password)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button {
                        testAndSave()
                    } label: {
                        HStack {
                            Spacer()
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text("测试连接并添加")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(name.isEmpty || serverUrl.isEmpty || username.isEmpty || isTesting)
                }
            }
            .navigationTitle("添加 WebDAV 来源")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func testAndSave() {
        guard let url = URL(string: serverUrl) else {
            errorMessage = "无效的 URL 格式"
            return
        }

        isTesting = true
        errorMessage = nil

        Task {
            do {
                let success = try await WebDAVClient.shared.testConnection(url: url, username: username, password: password)
                if success {
                    // Save password to Keychain
                    try KeychainService.shared.save(password: password, for: username)

                    let source = MusicSource(
                        name: name,
                        kind: .webdav,
                        webdavUrl: serverUrl,
                        webdavUsername: username,
                        syncStatus: "已连接"
                    )
                    UserDefaults.standard.set(username, forKey: "webdav_user_\(source.id)")

                    await MainActor.run {
                        modelContext.insert(source)
                        try? modelContext.save()
                        isTesting = false
                        dismiss()
                    }
                } else {
                    await MainActor.run {
                        errorMessage = "连接失败，请检查服务器地址与账号密码"
                        isTesting = false
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "网络连接异常：\(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}
