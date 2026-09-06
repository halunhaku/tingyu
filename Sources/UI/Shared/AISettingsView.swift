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
                Section {
                    Toggle("启用智能识别", isOn: $isEnabled)
                        .onChange(of: isEnabled) { _, newValue in
                            AIService.shared.isEnabled = newValue
                        }
                } header: {
                    Text("识别")
                } footer: {
                    Text("扫描时用大模型理解乱码或复杂文件名，还原歌名、歌手和专辑。")
                }

                if isEnabled {
                    Section {
                        Picker("服务商", selection: $selectedPreset) {
                            ForEach(AIProviderPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .onChange(of: selectedPreset) { _, newPreset in
                            baseURL = newPreset.defaultBaseURL
                            model = newPreset.defaultModel
                            saveSettings()
                        }

                        TextField("端点", text: $baseURL, prompt: Text("https://"))
                            .font(.body.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .onChange(of: baseURL) { _, _ in saveSettings() }

                        TextField("模型", text: $model)
                            .font(.body.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .onChange(of: model) { _, _ in saveSettings() }

                        SecureField("密钥", text: $apiKey)
                            .onChange(of: apiKey) { _, _ in saveSettings() }

                        HStack {
                            Button("测试连接") {
                                testConnection()
                            }
                            .disabled(apiKey.isEmpty || isTesting)

                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            if let msg = testResultMessage {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundStyle(msg.contains("成功") ? Color.green : Color.red)
                            }
                        }
                    } header: {
                        Text("服务商")
                    }

                    Section {
                        Button {
                            runAIDeepRefactor()
                        } label: {
                            if isRefactoring {
                                Text(refactorProgress)
                            } else {
                                Label("清洗整库", systemImage: "sparkles")
                            }
                        }
                        .disabled(apiKey.isEmpty || isRefactoring)
                    } header: {
                        Text("曲库")
                    } footer: {
                        Text("按当前配置批量识别已有曲目的歌名、歌手和专辑。")
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 420, idealWidth: 460, minHeight: 360)
            #endif
            .navigationTitle("AI 识别")
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
                    self.testResultMessage = ok ? "连接成功" : "未收到有效回复"
                    self.isTesting = false
                }
            } catch {
                await MainActor.run {
                    self.testResultMessage = "连接失败：\(error.localizedDescription)"
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

            for i in stride(from: 0, to: tracks.count, by: batchSize) {
                let end = min(i + batchSize, tracks.count)
                let slice = tracks[i..<end]

                let inputs = slice.map { AIInputItem(id: $0.id, filename: "\($0.title) \($0.filePathOrUrl)") }

                await MainActor.run {
                    self.refactorProgress = "识别中 (\(i)/\(tracks.count))"
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

                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            await MainActor.run {
                try? modelContext.save()
                self.isRefactoring = false
                self.refactorProgress = "完成"
            }

            Task {
                for track in tracks {
                    await MetadataEnricher.shared.enrichTrackIfNeeded(track)
                }
            }
        }
    }
}
