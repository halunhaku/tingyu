import WidgetKit
import SwiftUI
import AppIntents

public struct PlaybackEntry: TimelineEntry {
    public let date: Date
    public let info: WidgetTrackInfo

    public init(date: Date = Date(), info: WidgetTrackInfo = WidgetTrackInfo()) {
        self.date = date
        self.info = info
    }
}

public struct PlaybackTimelineProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> PlaybackEntry {
        PlaybackEntry(
            date: Date(),
            info: WidgetTrackInfo(
                title: "晴天",
                artist: "周杰伦",
                album: "叶惠美",
                isPlaying: true,
                duration: 269,
                currentTime: 100
            )
        )
    }

    public func getSnapshot(in context: Context, completion: @escaping (PlaybackEntry) -> Void) {
        let info = SharedPlaybackState.shared.load()
        completion(PlaybackEntry(date: Date(), info: info))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<PlaybackEntry>) -> Void) {
        let info = SharedPlaybackState.shared.load()
        let entry = PlaybackEntry(date: Date(), info: info)
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

public struct TingyuWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    public let entry: PlaybackEntry

    public init(entry: PlaybackEntry) {
        self.entry = entry
    }

    public var body: some View {
        switch family {
        case .systemSmall:
            smallView
        case .systemMedium:
            mediumView
        #if os(iOS)
        case .accessoryCircular:
            accessoryCircularView
        case .accessoryRectangular:
            accessoryRectangularView
        #endif
        default:
            mediumView
        }
    }

    // MARK: - Small Widget

    private var smallView: some View {
        ZStack(alignment: .bottomLeading) {
            // Background Artwork or Gradient
            if let data = entry.info.coverData {
                #if canImport(AppKit)
                if let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                #elseif canImport(UIKit)
                if let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                #endif
            } else {
                LinearGradient(
                    colors: [Color.indigo, Color.purple.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            // Dark gradient overlay for text legibility
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Info & Interactive Play Button
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.info.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(entry.info.artist)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }

                Spacer()

                Button(intent: WidgetPlayPauseIntent()) {
                    Image(systemName: entry.info.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
    }

    // MARK: - Medium Widget

    private var mediumView: some View {
        HStack(spacing: 14) {
            // Album Artwork
            ZStack {
                if let data = entry.info.coverData {
                    #if canImport(AppKit)
                    if let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    #elseif canImport(UIKit)
                    if let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    #endif
                } else {
                    LinearGradient(
                        colors: [Color.indigo, Color.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 90, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 3)

            // Content & Controls
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.info.title)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    Text("\(entry.info.artist) · \(entry.info.album)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Progress Bar
                ProgressView(value: min(entry.info.currentTime, max(entry.info.duration, 1.0)), total: max(entry.info.duration, 1.0))
                    .tint(.primary)

                // Interactive Intent Buttons
                HStack(spacing: 20) {
                    Button(intent: WidgetPreviousIntent()) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    Button(intent: WidgetPlayPauseIntent()) {
                        Image(systemName: entry.info.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    Button(intent: WidgetNextIntent()) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(16)
    }

    #if os(iOS)
    private var accessoryCircularView: some View {
        Button(intent: WidgetPlayPauseIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: entry.info.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
        }
    }

    private var accessoryRectangularView: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.info.isPlaying ? "waveform" : "music.note")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.info.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.info.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
    #endif
}

public struct TingyuWidget: Widget {
    public static let kind: String = "com.halunhaku.tingyu.widget"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: PlaybackTimelineProvider()) { entry in
            TingyuWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("正在播放")
        .description("在桌面或锁屏查看听屿当前播放的歌曲并快捷控制。")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
        #else
        .supportedFamilies([.systemSmall, .systemMedium])
        #endif
    }
}
