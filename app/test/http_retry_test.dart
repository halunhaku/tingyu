import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/sources/http_retry.dart';

/// 重试只覆盖"重试有意义"的失败，且次数有上限：
/// 来源同步的失败大多是暂时性的（流控、抖动），但错误的密码重试一百次也还是错。
void main() {
  test('可重试的状态码重放后成功', () async {
    const HttpRetry retry = HttpRetry(baseDelay: Duration.zero);
    int attempts = 0;

    final String result = await retry.run<String>(
      run: (int attempt) async {
        attempts++;
        if (attempt < 3) {
          throw StateError('暂时性失败');
        }
        return 'ok';
      },
      shouldRetry: (Object? error, String? result) => error != null,
    );

    expect(result, 'ok');
    expect(attempts, 3);
  });

  test('不可重试的失败立刻抛出，不做额外尝试', () async {
    const HttpRetry retry = HttpRetry(baseDelay: Duration.zero);
    int attempts = 0;
    Object? captured;

    try {
      await retry.run<String>(
        run: (int attempt) async {
          attempts++;
          throw const _Unauthorized();
        },
        shouldRetry: (Object? error, String? result) => error is! _Unauthorized,
      );
    } on Object catch (error) {
      captured = error;
    }

    expect(captured, isA<_Unauthorized>());
    expect(attempts, 1);
  });

  test('一直失败时按上限停止并把最后一次的异常抛出去', () async {
    const HttpRetry retry = HttpRetry(
      maxAttempts: 4,
      baseDelay: Duration.zero,
    );
    int attempts = 0;
    Object? captured;

    try {
      await retry.run<String>(
        run: (int attempt) async {
          attempts++;
          throw StateError('第 $attempt 次');
        },
        shouldRetry: (Object? error, String? result) => true,
      );
    } on Object catch (error) {
      captured = error;
    }

    expect(attempts, 4);
    expect((captured! as StateError).message, '第 4 次');
  });

  test('结果级重试：状态码 503 会被重放，401 不会', () {
    expect(HttpRetry.retryableStatus(503), isTrue);
    expect(HttpRetry.retryableStatus(429), isTrue);
    expect(HttpRetry.retryableStatus(500), isTrue);
    expect(HttpRetry.retryableStatus(404), isFalse);
    expect(HttpRetry.retryableStatus(401), isFalse);
    expect(HttpRetry.retryableStatus(403), isFalse);
    expect(HttpRetry.retryableStatus(null), isFalse);
  });

  test('退避按指数增长并受上限约束（抖动用固定随机源）', () async {
    final List<Duration> delays = <Duration>[];
    final HttpRetry retry = HttpRetry(
      maxAttempts: 4,
      baseDelay: const Duration(milliseconds: 100),
      maxDelay: const Duration(milliseconds: 250),
      // 抖动系数固定为 1.0，断言才能落在确定值上。
      random: _FixedRandom(0.5),
    );

    try {
      await retry.run<String>(
        run: (int attempt) async => throw StateError('失败'),
        shouldRetry: (Object? error, String? result) => true,
        onRetry:
            (int attempt, Object? error, String? result, Duration delay) =>
                delays.add(delay),
      );
    } on Object {
      // 预期：最后一次之后不再退避。
    }

    expect(delays, <Duration>[
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 200),
      const Duration(milliseconds: 250),
    ]);
  });
}

class _Unauthorized implements Exception {
  const _Unauthorized();
}

/// 固定抖动：`nextDouble()` 恒为 0.5 → 系数 0.8 + 0.5×0.4 = 1.0。
class _FixedRandom implements math.Random {
  const _FixedRandom(this.value);

  final double value;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => 0;
}
