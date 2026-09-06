import Foundation
import SwiftData

@MainActor
public final class MetadataEnricher {
    public static let shared = MetadataEnricher()

    public init() {}

    public func enrichTrackIfNeeded(_ track: Track) async {
        // 1. Smart parse and clean title/artist/album from messy filename
        let parsed = SmartTitleParser.parse(
            filename: track.title,
            fallbackArtist: track.artist,
            fallbackAlbum: track.album
        )

        let queryTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryArtist = (track.artist != "未知艺术家" && !track.artist.isEmpty) ? track.artist : parsed.artist
        let queryAlbum = (track.album != "未知专辑" && track.album != "夸克曲库" && !track.album.isEmpty) ? track.album : parsed.album

        // Guard against setting artist name as song title
        guard !queryTitle.isEmpty && queryTitle != queryArtist && queryTitle != "周杰伦" else {
            return
        }

        // Update track display strings if currently messy or default
        if (track.artist == "未知艺术家" || track.artist.isEmpty) && !queryArtist.isEmpty && queryArtist != "未知艺术家" {
            track.artist = queryArtist
        }
        if (track.album == "未知专辑" || track.album == "夸克曲库" || track.album.isEmpty) && !queryAlbum.isEmpty && queryAlbum != "未知专辑" {
            track.album = queryAlbum
        }
        if track.title.contains("-") || track.title.contains("_") || track.title.contains(".") || track.title.lowercased().hasSuffix(".mp3") || track.title.lowercased().hasSuffix(".flac") {
            track.title = queryTitle
        }

        // 2. Primary Pipeline for Chinese Music: QQ Music (Official copyright for Jay Chou & Chinese pop)
        if track.coverArtData == nil || track.artist == "未知艺术家" || track.album == "未知专辑" || track.album == "夸克曲库" {
            if let qqResult = await QQMusicScraper.shared.search(title: queryTitle, artist: queryArtist) {
                let matchName = qqResult.songName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let targetName = queryTitle.lowercased()

                if matchName.contains(targetName) || targetName.contains(matchName) {
                    if !qqResult.singerName.isEmpty {
                        track.artist = qqResult.singerName
                    }
                    if !qqResult.albumName.isEmpty {
                        track.album = qqResult.albumName
                    }
                    if track.coverArtData == nil {
                        if let coverData = await QQMusicScraper.shared.fetchCoverArt(albumMid: qqResult.albumMid) {
                            track.coverArtData = coverData
                        }
                    }
                }
            }
        }

        // 3. Primary Pipeline for Lyrics: LRCLIB (Verified timestamps for Jay Chou & international hits)
        if track.lyrics == nil || track.lyrics?.isEmpty == true {
            if let lyrics = await LRCLIBScraper.shared.fetchLyrics(
                trackTitle: track.title,
                artist: track.artist == "未知艺术家" ? "" : track.artist,
                album: track.album == "未知专辑" || track.album == "夸克曲库" ? "" : track.album,
                duration: track.duration
            ) {
                track.lyrics = lyrics
            }
        }

        // 4. Fallback Pipeline for Lyrics: NetEase Cloud Music
        if track.lyrics == nil || track.lyrics?.isEmpty == true {
            if let netEaseMatch = await NetEaseScraper.shared.search(title: track.title, artist: track.artist) {
                let matchName = netEaseMatch.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let targetName = track.title.lowercased()
                if matchName.contains(targetName) || targetName.contains(matchName) {
                    if let netEaseLrc = await NetEaseScraper.shared.fetchLyrics(songId: netEaseMatch.songId) {
                        track.lyrics = netEaseLrc
                    }
                }
            }
        }

        // 5. Fallback Pipeline for Cover: NetEase & iTunes Search API
        if track.coverArtData == nil {
            if let netEaseMatch = await NetEaseScraper.shared.search(title: track.title, artist: track.artist),
               let picUrl = netEaseMatch.picUrl {
                let matchName = netEaseMatch.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let targetName = track.title.lowercased()
                if matchName.contains(targetName) || targetName.contains(matchName) {
                    if let coverData = await NetEaseScraper.shared.fetchCoverArt(picUrl: picUrl) {
                        track.coverArtData = coverData
                    }
                }
            }
        }

        if track.coverArtData == nil {
            let searchAlbum = (track.album == "未知专辑" || track.album == "夸克曲库") ? track.title : track.album
            let searchArtist = track.artist == "未知艺术家" ? "" : track.artist
            if let coverData = await iTunesCoverScraper.shared.fetchCoverArtData(album: searchAlbum, artist: searchArtist) {
                track.coverArtData = coverData
            }
        }

        // Sync current player state if this track is currently active
        if AudioPlayerService.shared.currentTrack?.id == track.id {
            AudioPlayerService.shared.currentCoverData = track.coverArtData
            AudioPlayerService.shared.currentLyrics = track.lyrics
        }
    }
}
