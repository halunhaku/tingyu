import SwiftUI

public struct TrackRowView: View {
    public let track: Track
    public let isCurrent: Bool
    public let onPlay: () -> Void

    @Bindable var player = AudioPlayerService.shared
    @State private var showingManualMatch = false

    public init(track: Track, isCurrent: Bool, onPlay: @escaping () -> Void) {
        self.track = track
        self.isCurrent = isCurrent
        self.onPlay = onPlay
    }

    public var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    CoverArtView(data: track.coverArtData, size: 40, cornerRadius: 6)

                    if isCurrent && player.isPlaying {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.45))
                        Image(systemName: "waveform")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .symbolEffect(.variableColor.iterative.reversing)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 14, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                        .lineLimit(1)

                    Text("\(track.artist) · \(track.album)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)

            Button {
                track.isFavorite.toggle()
            } label: {
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 14))
                    .foregroundStyle(track.isFavorite ? Color.red : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)

            Text(formatDuration(track.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .contextMenu {
            Button {
                onPlay()
            } label: {
                Label("立即播放", systemImage: "play.fill")
            }

            Button {
                player.queue.insert(track, at: player.currentQueueIndex + 1)
            } label: {
                Label("下一首播放", systemImage: "text.insert")
            }

            Button {
                player.queue.append(track)
            } label: {
                Label("添加到播放列表", systemImage: "text.append")
            }

            Divider()

            Button {
                track.isFavorite.toggle()
            } label: {
                Label(track.isFavorite ? "取消收藏" : "加入收藏", systemImage: track.isFavorite ? "heart.slash" : "heart")
            }

            Divider()

            Button {
                showingManualMatch = true
            } label: {
                Label("重新匹配元数据...", systemImage: "sparkle.magnifyingglass")
            }
        }
        .sheet(isPresented: $showingManualMatch) {
            ManualMatchSheet(track: track)
        }
    }

    private func formatDuration(_ duration: Double) -> String {
        guard duration > 0 else { return "--:--" }
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
