import SwiftUI
import SwiftData

public struct ManualMatchSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    public let track: Track

    @State private var searchTitle: String
    @State private var searchArtist: String
    @State private var candidates: [QQMusicSearchResult] = []
    @State private var selectedCandidate: QQMusicSearchResult? = nil
    @State private var isSearching = false
    @State private var isApplying = false
    @State private var errorMessage: String? = nil

    public init(track: Track) {
        self.track = track
        _searchTitle = State(initialValue: track.title)
        _searchArtist = State(initialValue: track.artist == "未知艺术家" ? "" : track.artist)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search Header
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        TextField("歌曲名称", text: $searchTitle)
                            .textFieldStyle(.roundedBorder)
                        TextField("歌手名称 (选填)", text: $searchArtist)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            performSearch()
                        } label: {
                            if isSearching {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "magnifyingglass")
                            }
                            Text("搜索")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(searchTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                    }

                    HStack {
                        Text("当前音频：\(track.title) · \(track.artist) (\(formatDuration(track.duration)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                .padding(20)
                .background(Color.primary.opacity(0.03))

                Divider()

                // Candidates List
                List(selection: $selectedCandidate) {
                    if candidates.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "music.note.list")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary.opacity(0.6))
                            Text(isSearching ? "正在检索官方曲目..." : (errorMessage ?? "请输入歌名后点击搜索"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .listRowBackground(Color.clear)
                    } else {
                        Section("搜索候选结果（点击选择最契合的版本）") {
                            ForEach(candidates) { candidate in
                                let isSelected = selectedCandidate?.id == candidate.id
                                HStack(spacing: 14) {
                                    // Album Art Preview
                                    AsyncImage(url: URL(string: candidate.coverUrl)) { image in
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        ZStack {
                                            Color.gray.opacity(0.2)
                                            Image(systemName: "music.note")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)

                                    // Info
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.songName)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)

                                        Text("\(candidate.singerName) · 《\(candidate.albumName)》")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    // Duration
                                    Text(candidate.formattedDuration)
                                        .font(.system(size: 13).monospacedDigit())
                                        .foregroundStyle(.secondary)

                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                                        .font(.title3)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedCandidate = candidate
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)

                Divider()

                // Footer Actions
                HStack {
                    if let selected = selectedCandidate {
                        Text("已选：\(selected.songName) - \(selected.singerName) (《\(selected.albumName)》)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button("取消") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button {
                        applySelectedMatch()
                    } label: {
                        if isApplying {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                        }
                        Text("应用此匹配")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCandidate == nil || isApplying)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("重新匹配元数据")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear {
                performSearch()
            }
        }
        .frame(minWidth: 580, minHeight: 480)
    }

    // MARK: - Actions

    private func performSearch() {
        let title = searchTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        isSearching = true
        errorMessage = nil

        Task {
            let list = await QQMusicScraper.shared.searchCandidates(
                title: title,
                artist: searchArtist.trimmingCharacters(in: .whitespacesAndNewlines),
                limit: 15
            )

            await MainActor.run {
                self.candidates = list
                self.selectedCandidate = list.first
                self.isSearching = false
                if list.isEmpty {
                    self.errorMessage = "未找到相关歌曲，请尝试更换关键词搜索"
                }
            }
        }
    }

    private func applySelectedMatch() {
        guard let candidate = selectedCandidate else { return }
        isApplying = true

        Task {
            // 1. Update basic info
            await MainActor.run {
                track.title = candidate.songName
                track.artist = candidate.singerName
                track.album = candidate.albumName
            }

            // 2. Fetch high-res official cover
            if let coverData = await QQMusicScraper.shared.fetchCoverArt(albumMid: candidate.albumMid) {
                await MainActor.run {
                    track.coverArtData = coverData
                }
            }

            // 3. Fetch lyrics
            let lyrics = await LRCLIBScraper.shared.fetchLyrics(
                trackTitle: candidate.songName,
                artist: candidate.singerName,
                album: candidate.albumName,
                duration: candidate.duration > 0 ? candidate.duration : track.duration
            )

            await MainActor.run {
                if let lyrics = lyrics {
                    track.lyrics = lyrics
                }

                // If currently playing, sync live player state immediately
                if AudioPlayerService.shared.currentTrack?.id == track.id {
                    AudioPlayerService.shared.currentCoverData = track.coverArtData
                    AudioPlayerService.shared.currentLyrics = track.lyrics
                    NowPlayingManager.shared.update(with: track, isPlaying: AudioPlayerService.shared.isPlaying)
                    SharedPlaybackState.shared.save(track: track, isPlaying: AudioPlayerService.shared.isPlaying, currentTime: AudioPlayerService.shared.currentTime, duration: track.duration)
                }

                try? modelContext.save()
                isApplying = false
                dismiss()
            }
        }
    }

    private func formatDuration(_ duration: Double) -> String {
        guard duration > 0 else { return "--:--" }
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
