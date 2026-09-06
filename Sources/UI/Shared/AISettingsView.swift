import SwiftUI
import SwiftData

public struct AISettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allTracks: [Track]

    @State private var isEnabled: Bool = AIService.shared.isEnabled
    @State private var selectedPreset: AIProviderPreset = .deepseek
    @State private var baseURL: String = AIService.shared.baseURL
    @State private var model: String = AIService.shared.model
    @State private var apiKey: String = AIService.shared.getApiKey()
    @State private var isTesting = false
    @State private var testResultMessage: String? = nil
    @State private var isRefactoring = false
    @State private var refactorProgress: String = ""

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("AI 智能识别设置") {
                    Toggle("启用 AI 智能识别与洗库", isOn: $isEnabled)
                        .onChange(of: isEnabled) { _, newValue in
                            AIService.shared.isEnabled = newValue
                        }

                    Text("开启后，听屿将使用大模型在扫描时自动理解疑难杂症文件名，智能还原标准歌名、歌手与专辑。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isEnabled {
                    Section("大模型服务商预设") {
                        Picker("服务商预设", selection: $selectedPreset) {
                            ForEach(AIProviderPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .onChange(of: selectedPreset) { _, newPreset in
                            baseURL = newPreset.defaultBaseURL
                            model = newPreset.defaultModel
                            saveSettings()
                        }

                        TextField("API 端点 (Base URL)", text: $baseURL)
                            .font(.system(size: 13, design: .monospaced))
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .onChange(of: baseURL) { _, _ in saveSettings() }

                        TextField("模型名称 (Model)", text: $model)
                            .font(.system(size: 13, design: .monospaced))
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .onChange(of: model) { _, _ in saveSettings() }

                        SecureField("API Key 密钥", text: $apiKey)
                            .font(.system(size: 13, design: .monospaced))
                            .onChange(of: apiKey) { _, _ in saveSettings() }

                        HStack {
                            Button("测试连接") {
                                testConnection()
                            }
                            .disabled(apiKey.isEmpty || isTesting)

                            if isTesting {
                                ProgressView()
                                    .padding(.leading, 8)
                            }

                            if let msg = testResultMessage {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundStyle(msg.contains("成功") ? Color.green : Color.red)
                                    .padding(.leading, 8)
                            }
                        }
                    }

                    Section("曲库深度清洗") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("如果您的曲库中存在较多历史遗留的乱码、带有拼音或复杂后缀的歌曲，可以点击下方按钮进行全库深度识别。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                runAIDeepRefactor()
                            } label: {
                                HStack {
                                    Image(systemName: "sparkles")
                                    Text(isRefactoring ? refactorProgress : "一键 AI 深度重构曲库")
                                        .fontWeight(.semibold)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(apiKey.isEmpty || isRefactoring)

                            if isRefactoring {
                                ProgressView()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("AI 智能识别配置")
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
        }
        .frame(minWidth: 500, minHeight: 450)
    }

    private func saveSettings() {
        AIService.shared.baseURL = baseURL
        AIService.shared.model = model
        AIService.shared.setApiKey(apiKey)
    }

    private func testConnection() {
        isTesting = true
        testResultMessage = nil
        saveSettings()

        Task {
            do {
                let ok = try await AIService.shared.testConnection()
                await MainActor.run {
                    self.testResultMessage = ok ? "连接成功！大模型正常响应" : "未收到有效回复"
                    self.isTesting = false
                }
            } catch {
                await MainActor.run {
                    self.testResultMessage = "连接失败: \(error.localizedDescription)"
                    self.isTesting = false
                }
            }
        }
    }

    private func runAIDeepRefactor() {
        isRefactoring = true
        saveSettings()

        Task {
            let tracks = allTracks
            let batchSize = 25
            var processed = 0

            for i in stride(from: 0, to: tracks.count, by: batchSize) {
                let end = min(i + batchSize, tracks.count)
                let slice = tracks[i..<end]

                let inputs = slice.map { AIInputItem(id: $0.id, filename: "\($0.title) \($0.filePathOrUrl)") }

                await MainActor.run {
                    self.refactorProgress = "正在 AI 识别曲目 (\(i)/\(tracks.count))..."
                }

                if let map = try? await AIMetadataParser.parseBatch(items: inputs) {
                    await MainActor.run {
                        for track in slice {
                            if let info = map[track.id] {
                                if !info.title.isEmpty && info.title != "周杰伦" {
                                    track.title = info.title
                                }
                                if !info.artist.isEmpty {
                                    track.artist = info.artist
                                }
                                if !info.album.isEmpty {
                                    track.album = info.album
                                }
                            }
                        }
                    }
                }

                processed += slice.count
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            await MainActor.run {
                try? modelContext.save()
                self.isRefactoring = false
                self.refactorProgress = "AI 深度重构完成！"

                // Trigger background cover and lyrics scraper on the newly clean names
                Task {
                    for track in tracks {
                        await MetadataEnricher.shared.enrichTrackIfNeeded(track)
                    }
                }
            }
        }
    }
}
