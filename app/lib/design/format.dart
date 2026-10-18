/// 时长格式化：秒（库内存储格式）与 Duration 都走这里。
///
/// 全应用唯一口径（修审计 §3.4「两种时长格式」）：零/负时长一律 `--:--`。
String formatSeconds(double seconds) {
  if (seconds <= 0) {
    return '--:--';
  }
  return formatDuration(Duration(milliseconds: (seconds * 1000).round()));
}

String formatDuration(Duration duration) {
  if (duration <= Duration.zero) {
    return '--:--';
  }
  final int totalSeconds = duration.inSeconds;
  final String minutes = (totalSeconds ~/ 60).toString();
  final String seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  if (totalSeconds >= 3600) {
    final String hours = (totalSeconds ~/ 3600).toString();
    final String restMinutes = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    return '$hours:$restMinutes:$seconds';
  }
  return '$minutes:$seconds';
}

/// 同步/统计用的相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前 / 日期。
String formatRelativeTime(DateTime time, {DateTime? now}) {
  final DateTime reference = now ?? DateTime.now();
  final Duration delta = reference.difference(time);
  if (delta.isNegative || delta.inMinutes < 1) {
    return '刚刚';
  }
  if (delta.inMinutes < 60) {
    return '${delta.inMinutes} 分钟前';
  }
  if (delta.inHours < 24) {
    return '${delta.inHours} 小时前';
  }
  if (delta.inDays < 7) {
    return '${delta.inDays} 天前';
  }
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')}';
}

/// 曲目/专辑计数：中文语境下不带空格。
String formatCount(int count) => '$count 首';
