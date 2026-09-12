/// 时长格式化：秒（Double，库内存储格式）与 Duration 都走这里。
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

/// 文件大小（同步状态展示用）。
String formatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
}
