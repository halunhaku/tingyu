import SwiftUI
import SwiftData
import WebKit

public struct AddQuarkSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var currentStep = 1 // 1: Login, 2: Select Folder
    @State private var loginTab = 0 // 0: Web / QR, 1: Cookie Manual
    @State private var confirmedCookie: String? = nil
    @State private var manualCookie: String = ""
    @State private var statusMessage: String = "请在下方官方页面中扫码或登录"

    // Step 2: Folder selection
    @State private var currentFolderFid = "0"
    @State private var currentFolderName = "全部文件"
    @State private var folderPath: [(fid: String, name: String)] = [("0", "全部文件")]
    @State private var folderItems: [QuarkItem] = []
    @State private var isLoadingFolders = false
    @State private var selectedFolderFid: String = "0"
    @State private var selectedFolderName: String = "全部网盘"

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if currentStep == 1 {
                    step1LoginView
                } else {
                    step2FolderSelectionView
                }
            }
            .navigationTitle("添加夸克网盘")
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
        .frame(minWidth: 560, minHeight: 520)
    }

    // MARK: - Step 1: Login

    private var step1LoginView: some View {
        VStack(spacing: 12) {
            Picker("", selection: $loginTab) {
                Text("官方扫码 / 账号登录").tag(0)
                Text("手动填入 Cookie").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 32)
            .padding(.top, 12)

            if loginTab == 0 {
                VStack(spacing: 8) {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Native WebKit embed loading pan.quark.cn
                    QuarkWebLoginView { capturedCookie in
                        self.statusMessage = "登录成功！正在读取网盘目录..."
                        self.confirmedCookie = capturedCookie
                        self.proceedToFolderSelection(cookie: capturedCookie)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("填入夸克网页版登录 Cookie：")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $manualCookie)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 160)
                        .padding(8)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack {
                        #if os(macOS)
                        Button("粘贴剪贴板") {
                            if let clip = NSPasteboard.general.string(forType: .string) {
                                manualCookie = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .buttonStyle(.bordered)
                        #endif

                        Spacer()

                        Button("验证并下一步") {
                            verifyAndProceed(cookie: manualCookie.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(32)
                Spacer()
            }
        }
    }

    // MARK: - Step 2: Folder Selection

    private var step2FolderSelectionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Path breadcrumbs
            HStack(spacing: 6) {
                Text("当前位置：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(folderPath, id: \.fid) { item in
                    Button(item.name) {
                        navigateTo(fid: item.fid, name: item.name)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    if item.fid != folderPath.last?.fid {
                        Text("/")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            // Folders list
            List {
                Section("请选择存放音乐的文件夹") {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(selectedFolderFid == currentFolderFid ? Color.accentColor : Color.secondary.opacity(0.3))
                        VStack(alignment: .leading) {
                            Text("使用当前目录：\(currentFolderName)")
                                .font(.headline)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedFolderFid = currentFolderFid
                        selectedFolderName = currentFolderName
                    }

                    if isLoadingFolders {
                        HStack {
                            Spacer()
                            ProgressView("正在读取目录...")
                            Spacer()
                        }
                    } else {
                        let folders = folderItems.filter { $0.isFolder }
                        if folders.isEmpty {
                            Text("此目录下没有子文件夹")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(folders) { item in
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(Color.orange)
                                    Text(item.name)
                                        .font(.body)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    enterFolder(fid: item.id, name: item.name)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            // Confirmation Bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("选定曲库目录：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selectedFolderName)
                        .font(.headline)
                }

                Spacer()

                Button("完成并同步") {
                    finishAndSave()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Logic

    private func verifyAndProceed(cookie: String) {
        Task {
            let (_, _) = await QuarkDriveClient.shared.verifyCookie(cookie)
            await MainActor.run {
                self.confirmedCookie = cookie
                self.proceedToFolderSelection(cookie: cookie)
            }
        }
    }

    private func proceedToFolderSelection(cookie: String) {
        self.currentStep = 2
        loadFolderContents(fid: "0")
    }

    private func loadFolderContents(fid: String) {
        guard let cookie = confirmedCookie else { return }
        isLoadingFolders = true
        Task {
            do {
                let items = try await QuarkDriveClient.shared.listFolder(fid: fid, cookie: cookie)
                await MainActor.run {
                    self.folderItems = items
                    self.isLoadingFolders = false
                }
            } catch {
                await MainActor.run {
                    self.isLoadingFolders = false
                }
            }
        }
    }

    private func enterFolder(fid: String, name: String) {
        folderPath.append((fid, name))
        currentFolderFid = fid
        currentFolderName = name
        selectedFolderFid = fid
        selectedFolderName = name
        loadFolderContents(fid: fid)
    }

    private func navigateTo(fid: String, name: String) {
        if let index = folderPath.firstIndex(where: { $0.fid == fid }) {
            folderPath = Array(folderPath.prefix(through: index))
            currentFolderFid = fid
            currentFolderName = name
            selectedFolderFid = fid
            selectedFolderName = name
            loadFolderContents(fid: fid)
        }
    }

    private func finishAndSave() {
        guard let cookie = confirmedCookie else { return }

        let source = MusicSource(
            name: "夸克网盘 (\(selectedFolderName))",
            kind: .quark,
            quarkFolderFid: selectedFolderFid,
            quarkAccountName: "夸克用户",
            syncStatus: "正在扫描..."
        )

        try? QuarkCookieStore.save(cookie: cookie, sourceId: source.id)

        modelContext.insert(source)
        try? modelContext.save()
        dismiss()

        // Trigger initial scan in background
        Task {
            do {
                let tracks = try await QuarkDriveClient.shared.scan(
                    folderFid: selectedFolderFid,
                    sourceId: source.id,
                    cookie: cookie
                )

                await MainActor.run {
                    for track in tracks {
                        modelContext.insert(track)
                    }
                    source.trackCount = tracks.count
                    source.syncStatus = "已同步 \(tracks.count) 首"
                    source.lastSyncedAt = Date()
                    try? modelContext.save()
                }
            } catch {
                await MainActor.run {
                    source.syncStatus = "同步失败: \(error.localizedDescription)"
                    try? modelContext.save()
                }
            }
        }
    }
}

// MARK: - Native WKWebView for Quark Login

#if os(macOS)
struct QuarkWebLoginView: NSViewRepresentable {
    let onCookiesCaptured: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.targetWebView = webView
        let request = URLRequest(url: URL(string: "https://pan.quark.cn")!)
        webView.load(request)
        context.coordinator.startPolling()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookiesCaptured: onCookiesCaptured)
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onCookiesCaptured: (String) -> Void
        weak var targetWebView: WKWebView?
        private var hasCaptured = false

        init(onCookiesCaptured: @escaping (String) -> Void) {
            self.onCookiesCaptured = onCookiesCaptured
            super.init()
        }

        func startPolling() {
            Task { @MainActor [weak self] in
                while let self = self, !self.hasCaptured {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !self.hasCaptured else { break }
                    self.inspectCookies()
                }
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func inspectCookies() {
            guard !hasCaptured, let webView = targetWebView else { return }
            let urlString = webView.url?.absoluteString ?? ""

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.hasCaptured else { return }
                let quarkCookies = cookies.filter { $0.domain.contains("quark.cn") }
                let names = Set(quarkCookies.map { $0.name })

                let hasAuthToken = names.contains("__puus") || names.contains("__uid") || names.contains("_UP_A4A_11_")
                let hasEnteredDrive = urlString.contains("/list") || urlString.contains("clouddrive")

                if hasAuthToken && (hasEnteredDrive || names.contains("__puus")) {
                    let cookieString = quarkCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    Task {
                        let (isValid, _) = await QuarkDriveClient.shared.verifyCookie(cookieString)
                        if isValid {
                            await MainActor.run {
                                guard !self.hasCaptured else { return }
                                self.hasCaptured = true
                                self.onCookiesCaptured(cookieString)
                            }
                        }
                    }
                }
            }
        }
    }
}
#elseif os(iOS)
struct QuarkWebLoginView: UIViewRepresentable {
    let onCookiesCaptured: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.targetWebView = webView
        let request = URLRequest(url: URL(string: "https://pan.quark.cn")!)
        webView.load(request)
        context.coordinator.startPolling()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookiesCaptured: onCookiesCaptured)
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onCookiesCaptured: (String) -> Void
        weak var targetWebView: WKWebView?
        private var hasCaptured = false

        init(onCookiesCaptured: @escaping (String) -> Void) {
            self.onCookiesCaptured = onCookiesCaptured
            super.init()
        }

        func startPolling() {
            Task { @MainActor [weak self] in
                while let self = self, !self.hasCaptured {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !self.hasCaptured else { break }
                    self.inspectCookies()
                }
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func inspectCookies() {
            guard !hasCaptured, let webView = targetWebView else { return }
            let urlString = webView.url?.absoluteString ?? ""

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.hasCaptured else { return }
                let quarkCookies = cookies.filter { $0.domain.contains("quark.cn") }
                let names = Set(quarkCookies.map { $0.name })

                let hasAuthToken = names.contains("__puus") || names.contains("__uid") || names.contains("_UP_A4A_11_")
                let hasEnteredDrive = urlString.contains("/list") || urlString.contains("clouddrive")

                if hasAuthToken && (hasEnteredDrive || names.contains("__puus")) {
                    let cookieString = quarkCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    Task {
                        let (isValid, _) = await QuarkDriveClient.shared.verifyCookie(cookieString)
                        if isValid {
                            await MainActor.run {
                                guard !self.hasCaptured else { return }
                                self.hasCaptured = true
                                self.onCookiesCaptured(cookieString)
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
