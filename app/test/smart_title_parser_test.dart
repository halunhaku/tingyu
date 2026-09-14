import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/sources/scraper/smart_title_parser.dart';

void main() {
  test('去掉曲序编号与扩展名', () {
    expect(SmartTitleParser.parse('01. 晴天.mp3').title, '晴天');
    expect(SmartTitleParser.parse('12_七里香.flac').title, '七里香');
    expect(SmartTitleParser.parse('3 - 以父之名.mp3').title, '以父之名');
  });

  test('歌手 - 歌名（中文常见命名）', () {
    final ParsedSongInfo parsed = SmartTitleParser.parse('周杰伦 - 晴天');
    expect(parsed.title, '晴天');
    expect(parsed.artist, '周杰伦');
    expect(parsed.album, SmartTitleParser.fallbackAlbum);
  });

  test('歌名 - 歌手（第二段是已知艺术家）', () {
    final ParsedSongInfo parsed = SmartTitleParser.parse('明明就 - 周杰伦');
    expect(parsed.title, '明明就');
    expect(parsed.artist, '周杰伦');
  });

  test('三段式：歌手 - 歌名 - 专辑 与 歌名 - 歌手 - 专辑', () {
    final ParsedSongInfo albumFirst = SmartTitleParser.parse('周杰伦 - 晴天 - 叶惠美');
    expect(albumFirst.artist, '周杰伦');
    expect(albumFirst.title, '晴天');
    expect(albumFirst.album, '叶惠美');

    final ParsedSongInfo songFirst = SmartTitleParser.parse('花海-周杰伦-魔杰座');
    expect(songFirst.title, '花海');
    expect(songFirst.artist, '周杰伦');
    expect(songFirst.album, '魔杰座');
  });

  test('剥离音质/版本噪声标注', () {
    expect(SmartTitleParser.cleanPart('晴天 [HQ]'), '晴天');
    expect(SmartTitleParser.cleanPart('晴天 (Live)'), '晴天');
    expect(SmartTitleParser.cleanPart('晴天-320k'), '晴天');
    expect(SmartTitleParser.cleanPart('水管的友情 (纯音乐版)'), '水管的友情 (纯音乐版)');
  });

  test('无分隔符时整段作为标题，艺术家回落到占位值', () {
    final ParsedSongInfo parsed = SmartTitleParser.parse('七里香');
    expect(parsed.title, '七里香');
    expect(parsed.artist, SmartTitleParser.fallbackArtist);
    expect(parsed.album, SmartTitleParser.fallbackAlbum);
  });

  test('fallback 可覆盖（WebDAV / Quark 扫描时传入库内已有值）', () {
    final ParsedSongInfo parsed = SmartTitleParser.parse(
      '七里香',
      fallbackArtist: '周杰伦',
      fallbackAlbum: '七里香',
    );
    expect(parsed.artist, '周杰伦');
    expect(parsed.album, '七里香');
  });

  test('空串与纯噪声输入不抛异常', () {
    expect(SmartTitleParser.parse('').title, '');
    expect(SmartTitleParser.parse('   ').title, '');
    expect(SmartTitleParser.parse('---').title, '');
  });
}
