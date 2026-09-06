import Foundation

public struct LyricLine: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let time: TimeInterval
    public let text: String

    public init(id: UUID = UUID(), time: TimeInterval, text: String) {
        self.id = id
        self.time = time
        self.text = text
    }

    /// Parses standard LRC string formatted with [mm:ss.xx] or [mm:ss.xxx] timestamps
    public static func parse(lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let pattern = #"(?:\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\])+(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return fallbackLines(from: lrc)
        }

        let fullRange = NSRange(lrc.startIndex..<lrc.endIndex, in: lrc)
        let matches = regex.matches(in: lrc, options: [], range: fullRange)

        for match in matches {
            guard match.numberOfRanges >= 5,
                  let mRange = Range(match.range(at: 1), in: lrc),
                  let sRange = Range(match.range(at: 2), in: lrc),
                  let textRange = Range(match.range(at: 4), in: lrc)
            else { continue }

            let minutes = Double(lrc[mRange]) ?? 0.0
            let seconds = Double(lrc[sRange]) ?? 0.0
            var fraction = 0.0

            if let fRange = Range(match.range(at: 3), in: lrc) {
                let fString = String(lrc[fRange])
                if fString.count == 2 {
                    fraction = (Double(fString) ?? 0.0) / 100.0
                } else if fString.count == 3 {
                    fraction = (Double(fString) ?? 0.0) / 1000.0
                } else {
                    fraction = (Double(fString) ?? 0.0) / 10.0
                }
            }

            let text = lrc[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let totalSeconds = minutes * 60.0 + seconds + fraction
                lines.append(LyricLine(time: totalSeconds, text: text))
            }
        }

        if lines.isEmpty {
            return fallbackLines(from: lrc)
        }

        return lines.sorted { $0.time < $1.time }
    }

    private static func fallbackLines(from text: String) -> [LyricLine] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
            .enumerated()
            .map { index, line in
                LyricLine(time: Double(index * 4), text: line)
            }
    }
}
