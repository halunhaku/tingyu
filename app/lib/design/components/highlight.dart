import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens/tokens.dart';

/// 命中子串高亮：把 [query] 在 [text] 里出现的每一段染成强调色浅底。
///
/// 匹配口径与仓库层一致——**原文子串、区分大小写之外不做归一化**（不做拼音、
/// 不做词干），否则「高亮的字」与「被搜到的理由」会对不上。
/// 空查询原样返回，不额外包一层 `Text.rich`（避免无谓的重建）。
class TyHighlightedText extends StatelessWidget {
  const TyHighlightedText({
    super.key,
    required this.text,
    required this.query,
    this.style,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
    this.textAlign,
  });

  final String text;
  final String query;
  final TextStyle? style;
  final int maxLines;
  final TextOverflow overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final TyTokens ty = context.ty;
    final TextStyle effective =
        style ?? ty.typography.bodyM.copyWith(color: ty.colors.textPrimary);
    final String needle = query.trim();
    if (needle.isEmpty || !text.contains(needle)) {
      return Text(
        text,
        style: effective,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }
    final TextStyle hit = effective.copyWith(color: ty.colors.accent);
    final List<TextSpan> spans = <TextSpan>[];
    int cursor = 0;
    while (true) {
      final int index = text.indexOf(needle, cursor);
      if (index < 0) {
        spans.add(TextSpan(text: text.substring(cursor)));
        break;
      }
      if (index > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, index)));
      }
      spans.add(
        TextSpan(
          text: text.substring(index, index + needle.length),
          style: hit,
        ),
      );
      cursor = index + needle.length;
    }
    return Text.rich(
      TextSpan(style: effective, children: spans),
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}
