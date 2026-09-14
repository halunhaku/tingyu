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
            Form {
                Section {
                    if sources.isEmpty {
                        Text("还没有音乐来源。从下面选一种添加。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sources) { source in
                            sourceRow(source)
                        }
                        .onDelete(perform: deleteSources)
                    }

                    if isScanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(scanStatusMessage)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("已添加")
                }

                Section {
                    addSourceRow(
                        title: "本地文件夹",
                        subtitle: "选择电脑上的音乐目录",
                        systemImage: "folder.fill",
                        tint: .orange
                    ) {
                        #if os(macOS)
                        selectLocalFolderMacOS()
                        #else
                        showingLocalFolderImporter = true
                        #endif
                    }

                    addSourceRow(
                        title: "WebDAV",
                        subtitle: "群晖、坚果云、Nextcloud",
                        systemImage: "cloud.fill",
                        tint: .blue
                    ) {
                        showingAddWebDAV = true
                    }

                    addSourceRow(
                        title: "夸克网盘",
                        subtitle: "扫码登录，边下边播",
                        systemImage: "bolt.horizontal.circle.fill",
                        tint: .green
                    ) {
                        showingAddQuark = true
                    }
                } header: {
                    Text("添加来源")
                } footer: {
                    Text("本地目录使用系统授权，关闭应用后仍可读取。")
                }

                Section {
                    Toggle("iCloud 曲库同步", isOn: $cloudSync.isCloudSyncEnabled)
                    LabeledContent("状态") {
                        Text(cloudSync.statusMessage)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("同步曲库索引、收藏和播放列表，音频文件仍留在各自来源中。")
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 440, idealWidth: 480, minHeight: 380)
            #endif
            .navigationTitle("音乐来源")
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

    private func sourceRow(_ source: MusicSource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: sourceIcon(source.kind))
                .font(.title3)
                .foregroundStyle(sourceColor(source.kind))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                Text(source.syncStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(source.trackCount) 首")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                Task { await rescanSource(source) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("重新扫描")

            Button(role: .destructive) {
                sourceToDelete = source
                showingDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除此来源")
        }
        .padding(.vertical, 2)
    }

    private func addSourceRow(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
        }
        .buttonStyle(.plain)
    }

    private func sourceIcon(_ kind: SourceKind) -> String {
        switch kind {
        case .quark: return "bolt.horizontal.circle.fill"
        case .webdav: return "cloud.fill"
        case .local: return "folder.fill"
        }
    }

    private func sourceColor(_ kind: SourceKind) -> Color {
        switch kind {
        case .quark: return .green
        case .webdav: return .blue
        case .local: return .orange
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
                Section {
                    TextField("名称", text: $name, prompt: Text("例如：家里的群晖"))
                    TextField("服务器", text: $serverUrl, prompt: Text("https://"))
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("用户名", text: $username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("密码", text: $password)
                } header: {
                    Text("连接")
                } footer: {
                    Text("密码保存在钥匙串。推荐使用应用专用密码。")
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 380, idealWidth: 420, minHeight: 280)
            #endif
            .navigationTitle("添加 WebDAV")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        testAndSave()
                    }
                    .disabled(name.isEmpty || serverUrl.isEmpty || username.isEmpty || isTesting)
                }
            }
            .overlay {
                if isTesting {
                    ProgressView("正在测试连接…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
