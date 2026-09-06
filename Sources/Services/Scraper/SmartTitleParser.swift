import Foundation

public struct ParsedSongInfo: Sendable {
    public let title: String
    public let artist: String
    public let album: String

    public init(title: String, artist: String = "", album: String = "") {
        self.title = title
        self.artist = artist
        self.album = album
    }
}

public enum SmartTitleParser {
    /// Cleans file name noise and parses title, artist, and album from messy file strings
    public static func parse(
        filename: String,
        fallbackArtist: String = "未知艺术家",
        fallbackAlbum: String = "未知专辑"
    ) -> ParsedSongInfo {
        var clean = filename

        // 1. Strip audio extensions
        for ext in LocalLibraryScanner.supportedExtensions {
            if clean.lowercased().hasSuffix("." + ext) {
                clean = String(clean.dropLast(ext.count + 1))
                break
            }
        }

        // 2. Strip leading track numbers: e.g. "01. ", "02 - ", "01 ", "3."
        clean = stripLeadingNumbers(clean)

        // 3. Split by '-' or '_' or '|'
        let parts = clean.components(separatedBy: CharacterSet(charactersIn: "-_|"))
            .map { cleanPart($0) }
            .filter { !$0.isEmpty }

        if parts.count >= 3 {
            // Pattern A: 歌名 - 歌手 - 专辑 (e.g. 花海-周杰伦-魔杰座)
            if parts[1] == "周杰伦" || parts[1] == "周杰倫" || parts[1].contains("周杰") {
                return ParsedSongInfo(title: parts[0], artist: parts[1], album: parts[2])
            }
            // Pattern B: 歌手 - 歌名 - 专辑/版本 (e.g. 周杰伦 - 晴天 - 叶惠美, 黄雨勋 - 水管的友情 - 纯音乐版)
            let p0 = stripLeadingNumbers(parts[0])
            let p1 = stripLeadingNumbers(parts[1])
            let p2 = cleanPart(parts[2])
            return ParsedSongInfo(title: p1, artist: p0, album: p2)
        } else if parts.count == 2 {
            // Check if parts[1] is artist (e.g. 明明就 - 周杰伦)
            if parts[1] == "周杰伦" || parts[1] == "周杰倫" || parts[1].contains("周杰") {
                let p0 = stripLeadingNumbers(parts[0])
                let p1 = stripLeadingNumbers(parts[1])
                return ParsedSongInfo(title: p0, artist: p1, album: fallbackAlbum)
            }
            // Standard Chinese convention: 歌手 - 歌名 (e.g. 周杰伦 - .园游会 (Live))
            let p0 = stripLeadingNumbers(parts[0])
            let p1 = stripLeadingNumbers(parts[1])
            return ParsedSongInfo(title: p1, artist: p0, album: fallbackAlbum)
        } else if let first = parts.first, !first.isEmpty {
            return ParsedSongInfo(title: cleanPart(first), artist: fallbackArtist, album: fallbackAlbum)
        }

        return ParsedSongInfo(title: cleanPart(clean), artist: fallbackArtist, album: fallbackAlbum)
    }

    public static func cleanPart(_ str: String) -> String {
        var s = str.trimmingCharacters(in: CharacterSet(charactersIn: ". _- \t"))

        let noiseRegexes = [
            #"(?i)\s*\[(?:HQ|SQ|FLAC|Hi-Res|320k|128k|\d+kbps|无损|高品质|现场|Live|官方|伴奏|Remix).*?\]"#,
            #"(?i)\s*\((?:HQ|SQ|FLAC|Hi-Res|320k|128k|\d+kbps|无损|高品质|现场|Live|伴奏|Remix|韩语中字|live版).*?\)"#,
            #"(?i)[-_](?:320k|128k|flac|hq|sq)"#
        ]

        for pattern in noiseRegexes {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
            }
        }

        return s.trimmingCharacters(in: CharacterSet(charactersIn: ". _- \t"))
    }

    public static func stripLeadingNumbers(_ str: String) -> String {
        let pattern = #"^\s*\d{1,3}\s*[-._\s]\s*"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(str.startIndex..<str.endIndex, in: str)
            let result = regex.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: "")
            return result.trimmingCharacters(in: CharacterSet(charactersIn: ". _- \t"))
        }
        return str
    }
}
