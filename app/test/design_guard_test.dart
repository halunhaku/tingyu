import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 设计守卫（分阶段）：B2 只扫描 `lib/design/components/`。
///
/// 规则来自 `DESIGN.md` §0.5。页面层（`lib/features/**`）在逐页迁移完成后
/// 于 B7 纳入同一扫描，避免对尚未迁移的旧页面产生噪声。
void main() {
  final Directory components = Directory('lib/design/components');

  test('设计组件不含硬编码颜色、内联字体与结构魔法值', () {
    final List<String> problems = <String>[];
    for (final FileSystemEntity entity in components.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final String source = entity.readAsStringSync();
      problems.addAll(
        guardViolations(source).map(
          (String problem) => '${entity.path}: $problem',
        ),
      );
    }
    expect(problems, isEmpty, reason: problems.take(20).join('\n'));
  });

  test('守卫规则的正反样例', () {
    final String bad = File(
      'test/fixtures/guard/bad_component.dart.txt',
    ).readAsStringSync();
    final List<String> violations = guardViolations(bad);
    expect(violations.length, greaterThanOrEqualTo(5));

    final String good = File(
      'test/fixtures/guard/good_component.dart.txt',
    ).readAsStringSync();
    expect(guardViolations(good), isEmpty);
  });
}

/// 返回源码中的违规描述；行尾 `// guard-ok: 理由` 可豁免该行。
List<String> guardViolations(String source) {
  final List<String> violations = <String>[];
  final List<String> lines = source.split('\n');
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    if (line.contains('// guard-ok:')) {
      continue;
    }
    void flag(String rule) => violations.add('第 ${i + 1} 行：$rule -> ${line.trim()}');

    if (RegExp(r'\bColors\.(?!transparent\b)\w+').hasMatch(line)) {
      flag('硬编码 Colors.*（transparent 除外）');
    }
    if (RegExp(r'\bColor\(0x|\bColor\.fromARGB').hasMatch(line)) {
      flag('硬编码 Color(0x…)（请用 TyColors）');
    }
    if (RegExp(r'\bTextStyle\(').hasMatch(line)) {
      flag('内联 TextStyle（请用 ty.typography）');
    }
    if (RegExp(r'\bfontSize:\s*\d').hasMatch(line)) {
      flag('内联 fontSize（请用 ty.typography）');
    }
    if (RegExp(r'\bPlatform\.is\w+\(').hasMatch(line)) {
      flag('组件内平台分支（请用 context.traits）');
    }
  }

  // 跨行调用：SizedBox / EdgeInsets / BorderRadius.circular 的数字参数。
  final RegExp layoutCall = RegExp(
    r'(EdgeInsets\.(?:all|only|symmetric|fromLTRB)|SizedBox\.(?:height|width)|BorderRadius\.circular)\(([^()]*)\)',
    dotAll: true,
  );
  for (final RegExpMatch match in layoutCall.allMatches(source)) {
    final String args = match.group(2)!;
    for (final RegExpMatch number in RegExp(
      r'\b\d+(?:\.\d+)?\b',
    ).allMatches(args)) {
      final double value = double.parse(number.group(0)!);
      if (value == 0 || value == 1 || value == 2) {
        continue;
      }
      final int line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
      if (lines[line - 1].contains('// guard-ok:')) {
        continue;
      }
      violations.add(
        '第 $line 行：结构常量 $value（请用 TySpace/TyRadius/TySize）',
      );
    }
  }
  return violations;
}
