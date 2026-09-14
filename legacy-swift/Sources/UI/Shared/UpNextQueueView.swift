import SwiftUI

struct UpNextQueueView: View {
    @Bindable private var player = AudioPlayerService.shared
    @State private var hoveredTrackId: String?

    private var upcomingTracks: [(index: Int, track: Track)] {
        guard !player.queue.isEmpty else { return [] }
        let startIndex = player.currentQueueIndex + 1
        guard startIndex < player.queue.count else { return [] }
        return Array(player.queue.enumerated())[startIndex..<player.queue.count].map { ($0.offset, $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // MARK: - Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("待播清单")
                        .font(.system(size: 15, weight: .bold))
                    Text(player.queue.isEmpty ? "队列为空" : "剩余 \(upcomingTracks.count) 首歌曲")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !player.queue.isEmpty {
                    Button("清空") {
                        player.queue.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Divider()
                .padding(.horizontal, 12)

            // MARK: - Queue Content
            if player.queue.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("暂无待播歌曲")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Current Track
                        if let current = player.currentTrack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("正在播放")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 16)

                                HStack(spacing: 10) {
                                    CoverArtView(data: player.currentCoverData, size: 36, cornerRadius: 4)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(current.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.appleMusicRed)
                                            .lineLimit(1)
                                        Text(current.artist)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if player.isPlaying {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(Color.appleMusicRed)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.appleMusicRed.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .padding(.horizontal, 12)
                            }
                        }

                        // Upcoming Tracks
                        if !upcomingTracks.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("接下来播放")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 16)

                                LazyVStack(spacing: 2) {
                                    ForEach(upcomingTracks, id: \.track.id) { item in
                                        let isHovered = hoveredTrackId == item.track.id
                                        HStack(spacing: 10) {
                                            CoverArtView(data: item.track.coverArtData, size: 30, cornerRadius: 4)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(item.track.title)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .lineLimit(1)
                                                Text(item.track.artist)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer()

                                            if isHovered {
                                                Button {
                                                    if item.index < player.queue.count {
                                                        player.queue.remove(at: item.index)
                                                    }
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundStyle(.secondary)
                                                        .frame(width: 20, height: 20)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
                                        )
                                        .contentShape(Rectangle())
                                        .onHover { hovering in
                                            hoveredTrackId = hovering ? item.track.id : nil
                                        }
                                        .onTapGesture {
                                            player.setQueue(player.queue, startingAt: item.index)
                                        }
                                    }
                                }
                                .padding(.horizontal, 12)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 290, height: 380)
    }
}
