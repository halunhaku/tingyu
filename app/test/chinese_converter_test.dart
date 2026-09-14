import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/sources/scraper/chinese_converter.dart';

void main() {
  test('字表解析：取首个候选，忽略注释与空行', () {
    final Map<String, String> dictionary = ChineseConverter.parseDictionary('''
# 注释行
發	发
乾	干 乾
後	后

''');

    expect(dictionary['發'], '发');
    expect(dictionary['乾'], '干');
    expect(dictionary['後'], '后');
    expect(dictionary.containsKey('#'), isFalse);
  });

  test('转换繁体歌词，简体与未收录字符保持原样', () async {
    final ChineseConverter converter = ChineseConverter(
      loadDictionary: () async => '發\t发\n後\t后\n來\t来\n們\t们\n',
    );

    expect(await converter.toSimplified('後來的我們'), '后来的我们');
    expect(await converter.toSimplified('hello 世界'), 'hello 世界');
    expect(await converter.toSimplified(''), '');
  });

  test('真实 OpenCC 字表可加载（资产文件存在且可解析）', () async {
    final File asset = File('assets/opencc/TSCharacters.txt');
    expect(asset.existsSync(), isTrue, reason: '字表应随仓库提交');

    final ChineseConverter converter = ChineseConverter(loadDictionary: asset.readAsString);
    final String simplified = await converter.toSimplified('我們都已經長大，過去的那些年');

    expect(simplified, '我们都已经长大，过去的那些年');
  });
}
