/// 一行歌词。
class LrcLine {
  const LrcLine({required this.time, required this.text});

  final Duration time;

  final String text;
}

/// LRC / 纯文本歌词解析。
///
/// 支持一行多个时间戳（`[00:12.00][01:20.00]副歌`）、`[mm:ss]` 与 `[mm:ss.xx]`
/// 两种精度；`[ti:]` `[ar:]` 这类元信息标签忽略。无法解析成时间的行按纯文本处理。
class LrcParser {
  static final RegExp _timestamp = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// 解析结果；[isSynced] 为 false 表示这是纯文本歌词（没有时间轴）。
  static LrcDocument parse(String? raw) {
    final String text = (raw ?? '').trim();
    if (text.isEmpty) {
      return const LrcDocument(lines: <LrcLine>[], isSynced: false);
    }

    final List<LrcLine> lines = <LrcLine>[];
    for (final String rawLine in text.split('\n')) {
      final String line = rawLine.trimRight();
      if (line.isEmpty) {
        continue;
      }
      final Iterable<RegExpMatch> matches = _timestamp.allMatches(line);
      if (matches.isEmpty) {
        continue;
      }
      final String content = line.substring(matches.last.end).trim();
      for (final RegExpMatch match in matches) {
        final int minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
        final int seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
        final String fraction = match.group(3) ?? '0';
        final int milliseconds = switch (fraction.length) {
          1 => int.parse(fraction) * 100,
          2 => int.parse(fraction) * 10,
          _ => int.parse(fraction.padRight(3, '0').substring(0, 3)),
        };
        lines.add(
          LrcLine(
            time: Duration(minutes: minutes, seconds: seconds, milliseconds: milliseconds),
            text: content,
          ),
        );
      }
    }

    if (lines.isEmpty) {
      // 没有时间轴：整段当纯文本，保留换行。
      return LrcDocument(
        lines: text
            .split('\n')
            .map((String line) => LrcLine(time: Duration.zero, text: line.trimRight()))
            .toList(growable: false),
        isSynced: false,
      );
    }

    lines.sort((LrcLine a, LrcLine b) => a.time.compareTo(b.time));
    return LrcDocument(lines: lines, isSynced: true);
  }
}

/// 解析后的歌词文档。
class LrcDocument {
  const LrcDocument({required this.lines, required this.isSynced});

  final List<LrcLine> lines;

  final bool isSynced;

  bool get isEmpty => lines.isEmpty;

  /// 当前时间对应的歌词行下标；早于第一句时返回 0，超出末尾返回最后一行。
  int indexAt(Duration position) {
    if (lines.isEmpty) {
      return -1;
    }
    int result = 0;
    for (int index = 0; index < lines.length; index++) {
      if (lines[index].time <= position) {
        result = index;
      } else {
        break;
      }
    }
    return result;
  }
}
