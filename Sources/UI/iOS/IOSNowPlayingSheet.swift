import SwiftUI

#if os(iOS)
public struct IOSNowPlayingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var player = AudioPlayerService.shared

    @State private var showingLyrics = false

    public init() {}

    public var body: some View {
        ZStack {
            // Fluid blurred background
            FluidBackgroundView(coverData: player.currentCoverData)

            VStack(spacing: 0) {
                // Top Dismiss Handle & Bar
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.compact.down")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(width: 44, height: 44)

                    Spacer()

                    // Lyrics / Artwork Toggle
                    Button {
                        withAnimation(.spring) {
                            showingLyrics.toggle()
                        }
                    } label: {
                        Image(systemName: showingLyrics ? "music.note" : "quote.bubble")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(showingLyrics ? Color.accentColor : .white.opacity(0.7))
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                // Middle Content: Large Artwork OR Apple Music Synced Lyrics
                if showingLyrics {
                    AnimatedLyricsView(
                        lyricsText: player.currentLyrics,
                        currentTime: player.currentTime
                    ) { seekTime in
                        player.seek(to: seekTime)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    VStack {
                        Spacer()
                        CoverArtView(
                            data: player.currentCoverData,
                            size: min(UIScreen.main.bounds.width - 64, 340),
                            cornerRadius: 20
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 24, x: 0, y: 12)
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                // Bottom Track Info & Playback Controls
                VStack(spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(player.currentTrack?.title ?? "听屿")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Text(player.currentTrack?.artist ?? "未知艺术家")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }

                        Spacer()

                        if let track = player.currentTrack {
                            Button {
                                track.isFavorite.toggle()
                            } label: {
                                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                                    .font(.system(size: 22))
                                    .foregroundStyle(track.isFavorite ? Color.red : .white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Scrubber & Buttons
                    PlaybackControls()

                    // AirPlay route picker
                    HStack {
                        Spacer()
                        AirPlayPickerView(
                            tintColor: UIColor.white.withAlphaComponent(0.7),
                            activeTintColor: UIColor.white
                        )
                        .frame(width: 44, height: 44)
                        Spacer()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
    }
}
#endif
