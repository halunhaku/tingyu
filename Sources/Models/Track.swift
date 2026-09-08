import Foundation
import SwiftData

@Model
public final class Track: Identifiable {
    public var id: String = UUID().uuidString
    public var sourceId: String = ""
    public var title: String = ""
    public var artist: String = "未知艺术家"
    public var album: String = "未知专辑"
    public var duration: Double = 0.0
    public var trackNumber: Int? = nil
    public var discNumber: Int? = nil
    public var year: Int? = nil
    public var genre: String? = nil
    public var bitrate: Int? = nil
    public var sampleRate: Int? = nil
    public var fileFormat: String = "mp3"
    public var filePathOrUrl: String = ""
    public var fileSize: Int64 = 0
    public var etag: String? = nil
    public var lastModified: Date? = nil
    @Attribute(.externalStorage) public var coverArtData: Data? = nil
    public var coverArtUrl: String? = nil
    public var lyrics: String? = nil
    public var isFavorite: Bool = false
    public var dateAdded: Date = Date()
    public var playCount: Int = 0
    public var lastPlayedAt: Date? = nil
    public init(
        id: String = UUID().uuidString,
        sourceId: String,
        title: String,
        artist: String = "未知艺术家",
        album: String = "未知专辑",
        duration: Double = 0.0,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        bitrate: Int? = nil,
        sampleRate: Int? = nil,
        fileFormat: String = "mp3",
        filePathOrUrl: String,
        fileSize: Int64 = 0,
        etag: String? = nil,
        lastModified: Date? = nil,
        coverArtData: Data? = nil,
        coverArtUrl: String? = nil,
        lyrics: String? = nil,
        isFavorite: Bool = false,
        dateAdded: Date = Date(),
        playCount: Int = 0,
        lastPlayedAt: Date? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.fileFormat = fileFormat
        self.filePathOrUrl = filePathOrUrl
        self.fileSize = fileSize
        self.etag = etag
        self.lastModified = lastModified
        self.coverArtData = coverArtData
        self.coverArtUrl = coverArtUrl
        self.lyrics = lyrics
        self.isFavorite = isFavorite
        self.dateAdded = dateAdded
        self.playCount = playCount
        self.lastPlayedAt = lastPlayedAt
    }
}
