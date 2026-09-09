import SwiftUI
import AppKit
#if os(macOS)
struct MacOSNowPlayingStage: View {
    var onClose: () -> Void
    @Bindable private var player = AudioPlayerService.shared

    @State private var isShowingLyrics: Bool = true
    @State private var isHovering: Bool = false
    @State private var hideControlsTimer: Task<Void, Never>?

    private var hasLyrics: Bool {
        guard let lyrics = player.currentLyrics else { return false }
        return !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowLyricsColumn: Bool {
        hasLyrics && isShowingLyrics
    }

    var body: some View {
        ZStack {
            NowPlayingBackdrop(coverData: player.currentCoverData)

            HStack(alignment: .center, spacing: 56) {
                if !shouldShowLyricsColumn {
                    Spacer(minLength: 0)
                }

                VStack(spacing: 18) {
                    CoverArtView(
                        data: player.currentCoverData,
                        size: 320,
                        cornerRadius: 14
                    )
                    .shadow(color: .black.opacity(0.4), radius: 28, y: 16)

                    VStack(spacing: 8) {
                        HStack {
                            Text(formatTime(player.currentTime))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.65))

                            Spacer()

                            Text("-\(formatTime(remaining))")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.65))
                        }

                        MiniSeekBar(
                            current: player.currentTime,
                            duration: max(player.duration, 1)
                        ) { player.seek(to: $0) }
                    }
                    .frame(width: 320)

                    HStack(alignment: .center) {
                        if let track = player.currentTrack {
                            Button {
                                track.isFavorite.toggle()
                            } label: {
                                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(track.isFavorite ? Color.appleMusicRed : .white.opacity(0.7))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .help(track.isFavorite ? "取消喜爱" : "喜爱")
                        } else {
                            Color.clear.frame(width: 28, height: 28)
                        }

                        Spacer()

                        HStack(spacing: 28) {
                            Button {
                                player.previous()
                            } label: {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .buttonStyle(.plain)

                            Button {
                                player.togglePlayPause()
                            } label: {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .frame(width: 28)
                            }
                            .buttonStyle(.plain)

                            Button {
                                player.next()
                            } label: {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(.white)

                        Spacer()
                        HStack(spacing: 12) {
                            AirPlayPickerView(
                                normalColor: NSColor.white.withAlphaComponent(0.65),
                                activeColor: NSColor.white
                            )
                            .frame(width: 24, height: 24)
                            .help("隔空播放 (AirPlay)")

                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    isShowingLyrics.toggle()
                                }
                            } label: {
                                Image(systemName: isShowingLyrics ? "quote.bubble.fill" : "quote.bubble")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(isShowingLyrics ? .white : .white.opacity(0.45))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .help("歌词")

                            Button(action: onClose) {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .help("退出全屏 (Esc)")
                        }
                    }
                    .frame(width: 320)
                }
                .frame(width: 320)

                if shouldShowLyricsColumn {
                    AnimatedLyricsView(
                        lyricsText: player.currentLyrics,
                        currentTime: player.currentTime
                    ) { player.seek(to: $0) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, shouldShowLyricsColumn ? 64 : 32)
            .padding(.vertical, 36)
        }
    }

    private var remaining: Double {
        max(player.duration - player.currentTime, 0)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct NowPlayingBackdrop: View {
    let coverData: Data?

    var body: some View {
        ZStack {
            Color.black
            if let coverData, let nsImage = NSImage(data: coverData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.45)
                    .blur(radius: 80)
                    .saturation(1.35)
                    .overlay {
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.16),
                                Color.black.opacity(0.4)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
        }
        .clipped()
        .ignoresSafeArea()
    }
}

struct MacOSFloatingPlayerBar: View {
    @Binding var showingLyrics: Bool
    var showingNowPlaying: Bool = false
    var onToggleNowPlaying: (() -> Void)? = nil
    @Bindable private var player = AudioPlayerService.shared
    @State private var showingQueue: Bool = false

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
                        if let artist = player.currentTrack?.artist {
                            Text(artist)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        } else {
                            Text(player.playbackError ?? "选择一首歌曲")
                                .font(.system(size: 11))
                                .foregroundStyle(player.playbackError == nil ? Color.secondary : Color.red.opacity(0.85))
                                .lineLimit(1)
                        }
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
                    .foregroundStyle(showingLyrics ? Color.appleMusicRed : Color.primary)
            }
            .buttonStyle(.plain)
            .help("歌词面板 (⌘L)")

            Button {
                showingQueue.toggle()
            } label: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(showingQueue ? Color.appleMusicRed : Color.primary)
            }
            .buttonStyle(.plain)
            .help("待播清单")
            .popover(isPresented: $showingQueue, arrowEdge: .top) {
                UpNextQueueView()
            }

            AirPlayPickerView()
                .frame(width: 20, height: 20)
                .help("隔空播放 (AirPlay)")

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
                .foregroundStyle(accent ? Color.appleMusicRed : Color.primary)
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
                    .fill(Color.appleMusicRed.opacity(isDragging ? 0.95 : 0.8))
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
