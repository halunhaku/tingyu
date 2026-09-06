import Foundation
import AVFoundation
import MediaPlayer
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one
}

public enum PlayOrder: String, Codable, CaseIterable, Sendable {
    case sequential
    case shuffle
}

@MainActor
@Observable
public final class AudioPlayerService {
    public static let shared = AudioPlayerService()

    public var currentTrack: Track?
    public var currentCoverData: Data? = nil
    public var currentLyrics: String? = nil
    public var isPlaying: Bool = false
    public var currentTime: Double = 0.0
    public var duration: Double = 0.0
    public var volume: Float = 0.8 {
        didSet {
            player.volume = volume
        }
    }
    public var queue: [Track] = []
    public var originalQueue: [Track] = []
    public var currentQueueIndex: Int = 0
    public var repeatMode: RepeatMode = .off
    public var playOrder: PlayOrder = .sequential
    public var playbackError: String? = nil

    private var player: AVPlayer
    private var timeObserverToken: Any?
    private var itemEndObserver: (any NSObjectProtocol)?
    private var itemFailedObserver: (any NSObjectProtocol)?
    private var itemStatusObservation: NSKeyValueObservation?
    private var currentSecurityScopedUrl: URL?
    private var resourceLoaderDelegate: NSObject?
    private var cachedStreamFile: URL?
    private var modelContainer: ModelContainer?

    public init() {
        self.player = AVPlayer()
        self.player.volume = self.volume
        setupAudioSession()
        setupTimeObserver()
        setupEndObserver()
        setupFailedObserver()
    }

    public func configure(container: ModelContainer) {
        self.modelContainer = container
    }

    private func setupAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            print("Failed to set up AVAudioSession: \(error)")
        }
        #endif
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            if !seconds.isNaN && !seconds.isInfinite {
                Task { @MainActor in
                    guard let self = self else { return }
                    self.currentTime = seconds
                    NowPlayingManager.shared.updatePlaybackTime(seconds, duration: self.duration, isPlaying: self.isPlaying)
                }
            }
        }
    }

    private func setupEndObserver() {
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTrackDidEnd()
            }
        }
    }

    private func setupFailedObserver() {
        itemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                self?.isPlaying = false
                self?.playbackError = error.map { AudioPlayerService.describeError($0) } ?? "播放失败"
            }
        }
    }

    // MARK: - Queue & Playback

    public func setQueue(_ tracks: [Track], startingAt index: Int = 0) {
        self.originalQueue = tracks
        if playOrder == .shuffle {
            var shuffled = tracks
            let startingTrack = (index >= 0 && index < tracks.count) ? tracks[index] : tracks.first
            if let start = startingTrack {
                shuffled.removeAll { $0.id == start.id }
                shuffled.shuffle()
                self.queue = [start] + shuffled
                self.currentQueueIndex = 0
            } else {
                self.queue = tracks
                self.currentQueueIndex = index
            }
        } else {
            self.queue = tracks
            self.currentQueueIndex = index
        }

        if currentQueueIndex >= 0 && currentQueueIndex < queue.count {
            play(track: queue[currentQueueIndex])
        }
    }

    public func play(track: Track) {
        self.currentTrack = track
        self.duration = track.duration
        self.currentTime = 0.0
        self.currentCoverData = track.coverArtData
        self.currentLyrics = track.lyrics
        self.playbackError = nil

        releaseLocalAccess()

        if track.filePathOrUrl.hasPrefix("quark://") {
            playQuark(track: track)
            return
        }

        if track.filePathOrUrl.hasPrefix("http://") || track.filePathOrUrl.hasPrefix("https://") {
            playRemote(track: track)
            return
        }

        playLocal(track: track)
    }

    private func playQuark(track: Track) {
        let fid = track.filePathOrUrl.replacingOccurrences(of: "quark://", with: "")
        let cookie = QuarkCookieStore.load(sourceId: track.sourceId) ?? ""
        if cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isPlaying = false
            playbackError = "夸克登录已失效，请重新添加网盘"
            return
        }

        playbackError = nil
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let downloadUrl = try await QuarkDriveClient.shared.getDownloadUrl(fid: fid, cookie: cookie)
                let cdnCookie = QuarkDriveClient.shared.latestCookie(from: cookie)
                try? QuarkCookieStore.save(cookie: cdnCookie, sourceId: track.sourceId)

                let headers = QuarkDriveClient.playbackHeaders(cookie: cdnCookie)
                let ext = track.fileFormat.isEmpty ? "mp3" : track.fileFormat
                guard let loader = StreamingResourceLoader(
                    url: downloadUrl,
                    headers: headers,
                    fileExtension: ext
                ) else {
                    throw QuarkError.networkError("无法创建直链播放器")
                }

                self.resourceLoaderDelegate = loader
                let asset = AVURLAsset(url: loader.assetURL)
                asset.resourceLoader.setDelegate(loader, queue: loader.queue)
                self.startPlayback(asset: asset, track: track)
            } catch {
                self.isPlaying = false
                self.playbackError = Self.describeError(error)
                print("Failed to resolve Quark stream URL: \(error)")
            }
        }
    }

    private func replaceCachedStreamFile(with newFile: URL) {
        if let previous = cachedStreamFile, previous != newFile {
            try? FileManager.default.removeItem(at: previous)
        }
        cachedStreamFile = newFile
    }

    private func playRemote(track: Track) {
        guard let url = URL(string: track.filePathOrUrl) else {
            isPlaying = false
            playbackError = "无效的音频地址"
            return
        }

        let credentials = webdavCredentials(for: track.sourceId)
        let asset = makeRemoteAsset(url: url, credentials: credentials)
        startPlayback(asset: asset, track: track)
    }

    private func playLocal(track: Track) {
        guard let fileUrl = activateLocalFileURL(for: track) else {
            isPlaying = false
            playbackError = "无法访问本地文件。请在「音乐来源」中重新添加该文件夹。"
            return
        }

        if let loader = LocalAudioResourceLoader(fileURL: fileUrl) {
            resourceLoaderDelegate = loader
            let asset = AVURLAsset(url: loader.assetURL)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            startPlayback(asset: asset, track: track)
            return
        }

        let asset = AVURLAsset(url: fileUrl)
        startPlayback(asset: asset, track: track)
    }

    private func startPlayback(asset: AVURLAsset, track: Track) {
        let playerItem = AVPlayerItem(asset: asset)
        observeItemStatus(playerItem)
        player.replaceCurrentItem(with: playerItem)
        player.play()
        isPlaying = true

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                if !seconds.isNaN && !seconds.isInfinite && seconds > 0 {
                    self.duration = seconds
                    track.duration = seconds
                }
            }
        }

        NowPlayingManager.shared.update(with: track, isPlaying: true)
        SharedPlaybackState.shared.save(track: track, isPlaying: true, currentTime: 0, duration: duration)
    }

    private func observeItemStatus(_ item: AVPlayerItem) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self else { return }
                switch item.status {
                case .failed:
                    self.isPlaying = false
                    self.playbackError = item.error.map { Self.describeError($0) } ?? "无法播放此音频"
                case .readyToPlay:
                    if self.playbackError == nil, self.isPlaying {
                        self.player.play()
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: - Local security scope

    private func activateLocalFileURL(for track: Track) -> URL? {
        let storedPath = track.filePathOrUrl
        let storedFileURL = URL(fileURLWithPath: storedPath)
        let snapshot = sourceSnapshot(for: track.sourceId)

        if let bookmark = snapshot?.bookmarkData,
           let folderURL = try? LocalLibraryScanner.shared.resolveBookmark(data: bookmark) {
            let granted = folderURL.startAccessingSecurityScopedResource()
            if granted {
                currentSecurityScopedUrl = folderURL
            }

            let resolvedFile: URL
            if let folderPath = snapshot?.folderPath, storedPath.hasPrefix(folderPath) {
                let relative = String(storedPath.dropFirst(folderPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                resolvedFile = relative.isEmpty ? folderURL : folderURL.appendingPathComponent(relative)
            } else if storedPath.hasPrefix(folderURL.path) {
                let relative = String(storedPath.dropFirst(folderURL.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                resolvedFile = relative.isEmpty ? folderURL : folderURL.appendingPathComponent(relative)
            } else {
                resolvedFile = storedFileURL
            }

            if FileManager.default.isReadableFile(atPath: resolvedFile.path) {
                return resolvedFile
            }
        }

        // Last resort: the reconstructed file URL itself (works outside sandbox).
        if storedFileURL.startAccessingSecurityScopedResource() {
            currentSecurityScopedUrl = storedFileURL
        }
        if FileManager.default.isReadableFile(atPath: storedFileURL.path) {
            return storedFileURL
        }
        return nil
    }

    private func releaseLocalAccess() {
        currentSecurityScopedUrl?.stopAccessingSecurityScopedResource()
        currentSecurityScopedUrl = nil
        resourceLoaderDelegate = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
    }

    private struct SourceSnapshot {
        var kind: SourceKind
        var bookmarkData: Data?
        var folderPath: String?
        var webdavUsername: String?
    }

    private func sourceSnapshot(for sourceId: String) -> SourceSnapshot? {
        guard let container = modelContainer else { return nil }
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<MusicSource>(predicate: #Predicate { $0.id == sourceId })
        descriptor.fetchLimit = 1
        guard let source = try? context.fetch(descriptor).first else { return nil }
        return SourceSnapshot(
            kind: source.kind,
            bookmarkData: source.localBookmarkData,
            folderPath: source.localFolderPath,
            webdavUsername: source.webdavUsername
        )
    }

    private func webdavCredentials(for sourceId: String) -> (username: String, password: String)? {
        let username = sourceSnapshot(for: sourceId)?.webdavUsername
            ?? UserDefaults.standard.string(forKey: "webdav_user_\(sourceId)")
        guard let username, let password = KeychainService.shared.get(for: username) else {
            return nil
        }
        return (username, password)
    }

    private func makeRemoteAsset(url: URL, credentials: (username: String, password: String)?) -> AVURLAsset {
        guard let credentials else {
            return AVURLAsset(url: url)
        }

        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let space = URLProtectionSpace(
            host: url.host ?? "",
            port: port,
            protocol: url.scheme,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let credential = URLCredential(
            user: credentials.username,
            password: credentials.password,
            persistence: .forSession
        )
        URLCredentialStorage.shared.setDefaultCredential(credential, for: space)

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = credentials.username
        components?.password = credentials.password
        let authenticatedURL = components?.url ?? url

        let token = "\(credentials.username):\(credentials.password)"
        var options: [String: Any] = [:]
        if let data = token.data(using: .utf8) {
            options["AVURLAssetHTTPHeaderFieldsKey"] = [
                "Authorization": "Basic \(data.base64EncodedString())"
            ]
        }
        return AVURLAsset(url: authenticatedURL, options: options)
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    public func resume() {
        if player.currentItem == nil, let track = currentTrack {
            play(track: track)
        } else {
            player.play()
            isPlaying = true
            NowPlayingManager.shared.updatePlaybackRate(1.0)
        }
        SharedPlaybackState.shared.save(track: currentTrack, isPlaying: true, currentTime: currentTime, duration: duration)
    }

    public func pause() {
        player.pause()
        isPlaying = false
        NowPlayingManager.shared.updatePlaybackRate(0.0)
        SharedPlaybackState.shared.save(track: currentTrack, isPlaying: false, currentTime: currentTime, duration: duration)
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTrack = nil
        currentTime = 0.0
        currentCoverData = nil
        currentLyrics = nil
        playbackError = nil
        if let previous = cachedStreamFile {
            try? FileManager.default.removeItem(at: previous)
            cachedStreamFile = nil
        }
        releaseLocalAccess()
        NowPlayingManager.shared.clear()
        SharedPlaybackState.shared.save(track: nil, isPlaying: false, currentTime: 0, duration: 0)
    }

    public func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        self.currentTime = seconds
        NowPlayingManager.shared.updatePlaybackTime(seconds, duration: self.duration, isPlaying: self.isPlaying)
        SharedPlaybackState.shared.save(track: currentTrack, isPlaying: isPlaying, currentTime: seconds, duration: duration)
    }

    public func next() {
        guard !queue.isEmpty else { return }
        if repeatMode == .one {
            seek(to: 0)
            resume()
            return
        }

        let nextIndex = currentQueueIndex + 1
        if nextIndex < queue.count {
            currentQueueIndex = nextIndex
            play(track: queue[currentQueueIndex])
        } else if repeatMode == .all {
            currentQueueIndex = 0
            play(track: queue[0])
        } else {
            pause()
            seek(to: 0)
        }
    }

    public func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 4.0 {
            seek(to: 0)
            return
        }

        let prevIndex = currentQueueIndex - 1
        if prevIndex >= 0 {
            currentQueueIndex = prevIndex
            play(track: queue[currentQueueIndex])
        } else if repeatMode == .all {
            currentQueueIndex = queue.count - 1
            play(track: queue[currentQueueIndex])
        } else {
            seek(to: 0)
        }
    }

    public func togglePlayOrder() {
        if playOrder == .sequential {
            playOrder = .shuffle
            if let current = currentTrack {
                var shuffled = queue
                shuffled.removeAll { $0.id == current.id }
                shuffled.shuffle()
                queue = [current] + shuffled
                currentQueueIndex = 0
            } else {
                queue.shuffle()
                currentQueueIndex = 0
            }
        } else {
            playOrder = .sequential
            if let current = currentTrack {
                queue = originalQueue
                currentQueueIndex = originalQueue.firstIndex(where: { $0.id == current.id }) ?? 0
            } else {
                queue = originalQueue
                currentQueueIndex = 0
            }
        }
    }

    public func cycleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
    }

    private func handleTrackDidEnd() {
        next()
    }

    static func describeError(_ error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = [nsError.localizedDescription]
        if nsError.domain != NSCocoaErrorDomain {
            parts.append("[\(nsError.domain) \(nsError.code)]")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("(\(underlying.domain) \(underlying.code))")
        }
        return parts.joined(separator: " ")
    }
}
