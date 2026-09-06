import SwiftUI

#if os(macOS)
public struct MacOSPlayerBar: View {
    @Binding var showingLyrics: Bool
    @Bindable var player = AudioPlayerService.shared

    public init(showingLyrics: Binding<Bool>) {
        self._showingLyrics = showingLyrics
    }

    public var body: some View {
        HStack(spacing: 20) {
            // Track Info
            HStack(spacing: 12) {
                CoverArtView(data: player.currentCoverData, size: 48, cornerRadius: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.title ?? "听屿")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(player.playbackError ?? player.currentTrack?.artist ?? "选择一首歌曲开始播放")
                        .font(.system(size: 11))
                        .foregroundStyle(player.playbackError == nil ? Color.secondary : Color.red.opacity(0.85))
                        .lineLimit(2)
                        .help(player.playbackError ?? "")
                }
            }
            .frame(width: 220, alignment: .leading)

            Spacer()

            // Controls & Scrubber
            VStack(spacing: 4) {
                PlaybackControls()
            }
            .frame(maxWidth: 520)

            Spacer()

            // Volume & Lyrics Toggle
            HStack(spacing: 16) {
                // Volume Slider
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(
                        value: Binding(
                            get: { Double(player.volume) },
                            set: { player.volume = Float($0) }
                        ),
                        in: 0...1
                    )
                    .frame(width: 80)

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    withAnimation(.spring) {
                        showingLyrics.toggle()
                    }
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 14))
                        .foregroundStyle(showingLyrics ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 220, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
#endif
