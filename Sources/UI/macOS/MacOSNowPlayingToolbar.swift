import SwiftUI

#if os(macOS)
struct MacOSNowPlayingStage: View {
    var onClose: () -> Void
    @Bindable private var player = AudioPlayerService.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 20) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("返回曲库")
                    Spacer()
                }
                .padding(.leading, 8)

                Spacer(minLength: 12)
                CoverArtView(
                    data: player.currentCoverData,
                    size: 280,
                    cornerRadius: 12
                )
                VStack(spacing: 6) {
                    Text(player.currentTrack?.title ?? "未在播放")
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(player.currentTrack?.artist ?? "")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 320)
                HStack(spacing: 8) {
                    Text(formatTime(player.currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    MiniSeekBar(
                        current: player.currentTime,
                        duration: max(player.duration, 1)
                    ) { player.seek(to: $0) }
                    Text(formatTime(player.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 320)
                Spacer(minLength: 80)
            }
            .frame(maxWidth: .infinity)

            AnimatedLyricsView(
                lyricsText: player.currentLyrics,
                currentTime: player.currentTime
            ) { player.seek(to: $0) }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct MacOSFloatingPlayerBar: View {
    @Binding var showingLyrics: Bool
    var showingNowPlaying: Bool = false
    var onToggleNowPlaying: (() -> Void)? = nil
    @Bindable private var player = AudioPlayerService.shared

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 14) {
                iconButton(
                    "shuffle",
                    accent: player.playOrder == .shuffle,
                    help: "随机播放"
                ) {
                    player.togglePlayOrder()
                }
                iconButton("backward.fill", help: "上一首") {
                    player.previous()
                }
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .help(player.isPlaying ? "暂停" : "播放")
                iconButton("forward.fill", help: "下一首") {
                    player.next()
                }
                iconButton(
                    player.repeatMode == .one ? "repeat.1" : "repeat",
                    accent: player.repeatMode != .off,
                    help: "循环"
                ) {
                    player.cycleRepeatMode()
                }
            }

            Button {
                onToggleNowPlaying?()
            } label: {
                HStack(spacing: 8) {
                    CoverArtView(
                        data: player.currentCoverData,
                        size: 36,
                        cornerRadius: 6,
                        showsShadow: false
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.title ?? "听屿")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(player.playbackError ?? player.currentTrack?.artist ?? "选择一首歌曲")
                            .font(.system(size: 11))
                            .foregroundStyle(player.playbackError == nil ? Color.secondary : Color.red.opacity(0.85))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 180, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showingNowPlaying ? "返回曲库" : "正在播放")

            if player.duration > 0 {
                HStack(spacing: 6) {
                    Text(formatTime(player.currentTime))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    MiniSeekBar(
                        current: player.currentTime,
                        duration: player.duration
                    ) { player.seek(to: $0) }
                    Text(formatTime(player.duration))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 220)
            }

            Spacer(minLength: 8)

            Button {
                onToggleNowPlaying?()
            } label: {
                Image(systemName: showingNowPlaying ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help(showingNowPlaying ? "返回曲库" : "正在播放")

            Button {
                showingLyrics.toggle()
            } label: {
                Image(systemName: "quote.bubble")
                    .foregroundStyle(showingLyrics ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .help("歌词面板 (⌘L)")

            MacOSVolumeToolbarItem()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .playerBarChrome()
    }

    private func iconButton(
        _ systemName: String,
        accent: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent ? Color.accentColor : Color.primary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MiniSeekBar: View {
    let current: Double
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var isDragging = false
    @State private var dragValue = 0.0

    private var fraction: CGFloat {
        let d = max(duration, 0.001)
        let t = isDragging ? dragValue : current
        return CGFloat(min(max(t / d, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.12))
                Capsule()
                    .fill(.primary.opacity(isDragging ? 0.7 : 0.5))
                    .frame(width: max(3, geo.size.width * fraction))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let x = min(max(value.location.x, 0), geo.size.width)
                        dragValue = duration * Double(x / max(geo.size.width, 1))
                    }
                    .onEnded { _ in
                        onSeek(dragValue)
                        isDragging = false
                    }
            )
        }
        .frame(height: 12)
    }
}

struct MacOSVolumeToolbarItem: View {
    @Bindable private var player = AudioPlayerService.shared
    @State private var showingSlider = false

    var body: some View {
        Button {
            showingSlider.toggle()
        } label: {
            Image(systemName: volumeSymbol)
        }
        .buttonStyle(.plain)
        .help("音量")
        .popover(isPresented: $showingSlider, arrowEdge: .top) {
            Slider(
                value: Binding(
                    get: { Double(player.volume) },
                    set: { player.volume = Float($0) }
                ),
                in: 0...1
            )
            .frame(width: 130)
            .padding(12)
        }
    }

    private var volumeSymbol: String {
        if player.volume <= 0.001 { return "speaker.slash.fill" }
        if player.volume < 0.33 { return "speaker.wave.1.fill" }
        if player.volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

private extension View {
    @ViewBuilder
    func playerBarChrome() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear.interactive(), in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
        }
    }
}
#endif
