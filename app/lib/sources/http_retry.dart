import 'dart:async';
import 'dart:math' as math;

/// 幂等网络请求的有限重试。
///
/// 为什么需要：来源同步里的失败几乎都是暂时性的 —— 坚果云的流控、夸克的风控、
/// 家用宽带的一次抖动。此前任何一次失败都会让整次扫描/播放失败，用户只能反复手点
/// "同步"。这里对**可安全重放**的请求（列目录、PROPFIND、取直链）做指数退避重试，
/// 且只重试"重试有意义"的失败：连接层错误、429、503 与 5xx。
///
/// 不重试的：401/403（凭据或权限不对）、404（文件真的不在）、其它 4xx
/// （请求本身不合法，重放只会再失败一次）。
class HttpRetry {
  const HttpRetry({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 400),
    this.maxDelay = const Duration(seconds: 8),
    this.random,
  });

  /// 含首次在内的尝试次数。
  final int maxAttempts;

  /// 第一次退避时长；之后指数增长。
  final Duration baseDelay;

  /// 退避上限。
  final Duration maxDelay;

  /// 抖动来源（测试注入固定序列，避免用例依赖随机数）。
  final math.Random? random;

  /// 执行 [run]，按 [shouldRetry] 决定是否重放。
  ///
  /// [run] 收到的是从 1 开始的尝试序号；[shouldRetry] 判断"这次的结果/异常是否值得
  /// 重试"；[onRetry] 可选，用于打印"第几次重试、因为什么"。
  Future<T> run<T>({
    required Future<T> Function(int attempt) run,
    required bool Function(Object? error, T? result) shouldRetry,
    void Function(int attempt, Object? error, T? result, Duration delay)? onRetry,
  }) async {
    Object? lastError;
    T? lastResult;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final T result = await run(attempt);
        lastResult = result;
        lastError = null;
        if (attempt >= maxAttempts || !shouldRetry(null, result)) {
          return result;
        }
      } on Object catch (error) {
        lastError = error;
        lastResult = null;
        if (attempt >= maxAttempts || !shouldRetry(error, null)) {
          rethrow;
        }
      }
      final Duration delay = _delayFor(attempt);
      onRetry?.call(attempt, lastError, lastResult, delay);
      await Future<void>.delayed(delay);
    }
    // 循环里要么 return 要么 rethrow，这里只是让类型系统闭嘴。
    throw StateError('HttpRetry 未产生结果: $lastError');
  }

  /// 第 [attempt] 次失败后的等待时长：baseDelay × 2^(attempt-1)，带 ±20% 抖动。
  ///
  /// 抖动是为了避免多个来源/多首曲目同时退避后在同一毫秒一起重试（惊群）。
  Duration _delayFor(int attempt) {
    final int exponent = math.max(0, attempt - 1);
    final int raw = baseDelay.inMilliseconds * math.pow(2, exponent).toInt();
    final int capped = math.min(raw, maxDelay.inMilliseconds);
    final math.Random source = random ?? math.Random();
    final double jitter = 0.8 + source.nextDouble() * 0.4;
    return Duration(milliseconds: math.max(1, (capped * jitter).round()));
  }

  /// HTTP 状态码是否值得重试。
  static bool retryableStatus(int? status) {
    if (status == null) {
      return false;
    }
    return status == 429 || status == 503 || status >= 500;
  }
}
