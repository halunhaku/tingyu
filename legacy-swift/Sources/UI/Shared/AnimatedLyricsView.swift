import SwiftUI

public struct AnimatedLyricsView: View {
    public let lyricsText: String?
    public let currentTime: Double
    public let onSeek: (Double) -> Void

    @State private var lines: [LyricLine] = []
    @State private var currentLineId: UUID?
    @State private var userIsScrolling: Bool = false

    public init(lyricsText: String?, currentTime: Double, onSeek: @escaping (Double) -> Void) {
        self.lyricsText = lyricsText
        self.currentTime = currentTime
        self.onSeek = onSeek
    }

    public var body: some View {
        Group {
            if lines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("暂无歌词")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            Color.clear.frame(height: 120)

                            ForEach(lines) { line in
                                let isActive = line.id == currentLineId
                                Button {
                                    onSeek(line.time)
                                } label: {
                                    Text(line.text)
                                        .font(.system(size: isActive ? 28 : 22, weight: isActive ? .bold : .medium, design: .rounded))
                                        .foregroundStyle(isActive ? .white : .white.opacity(0.42))
                                        .scaleEffect(isActive ? 1.03 : 1.0, anchor: .leading)
                                        .blur(radius: isActive ? 0 : 0.4)
                                        .animation(.spring, value: isActive)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .id(line.id)
                            }

                            Color.clear.frame(height: 200)
                        }
                        .padding(.horizontal, 32)
                    }
                    .onChange(of: currentTime) { _, newTime in
                        updateActiveLine(time: newTime, proxy: proxy)
                    }
                }
            }
        }
        .onAppear {
            parseLyrics()
        }
        .onChange(of: lyricsText) { _, _ in
            parseLyrics()
        }
    }

    private func parseLyrics() {
        if let text = lyricsText, !text.isEmpty {
            self.lines = LyricLine.parse(lrc: text)
        } else {
            self.lines = []
        }
    }

    private func updateActiveLine(time: Double, proxy: ScrollViewProxy) {
        guard !lines.isEmpty else { return }

        // Find current line based on time
        var active: LyricLine? = nil
        for line in lines {
            if line.time <= time {
                active = line
            } else {
                break
            }
        }

        if let active = active, active.id != currentLineId {
            withAnimation(.spring) {
                self.currentLineId = active.id
                proxy.scrollTo(active.id, anchor: .center)
            }
        }
    }
}
