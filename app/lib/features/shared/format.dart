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
