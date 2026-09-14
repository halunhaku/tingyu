import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/features/library/manual_match_dialog.dart';
import 'package:tingyu/sources/scraper/metadata_provider.dart';

void main() {
  group('buildMetadataSearchQuery', () {
    test('只要歌名', () {
      expect(buildMetadataSearchQuery(title: '七里香'), '七里香');
    });

    test('拼上歌手与专辑', () {
      expect(
        buildMetadataSearchQuery(title: '七里香', artist: '周杰伦', album: '叶惠美'),
        '七里香 周杰伦 叶惠美',
      );
    });

    test('空歌名不搜', () {
      expect(buildMetadataSearchQuery(title: '  ', artist: '周杰伦'), '');
    });

    test('占位歌手与专辑不进查询', () {
      expect(
        buildMetadataSearchQuery(
          title: 'qingtian',
          artist: '未知艺术家',
          album: '夸克曲库',
        ),
        'qingtian',
      );
      expect(
        buildMetadataSearchQuery(title: '晴天', artist: '周杰伦', album: '未知专辑'),
        '晴天 周杰伦',
      );
      expect(
        buildMetadataSearchQuery(title: '晴天', album: 'WebDAV 曲库'),
        '晴天',
      );
    });
  });

  testWidgets('打开匹配对话框先填字段，不自动搜索', (WidgetTester tester) async {
    final Track track = Track(
      id: 't1',
      sourceId: 's1',
      title: 'qingtian',
      artist: '未知艺术家',
      album: '夸克曲库',
      duration: 269,
      fileFormat: 'flac',
      filePathOrUrl: 'https://example/qingtian.flac',
      fileSize: 1,
      isFavorite: false,
      dateAdded: DateTime.utc(2026, 1, 1),
      playCount: 0,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              return TextButton(
                onPressed: () => showManualMatchDialog(context, ref, track),
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('匹配元数据'), findsOneWidget);
    expect(find.text('先填写歌名，再点搜索'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    final List<TextField> fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields, hasLength(3));
    expect(fields[0].controller?.text, 'qingtian');
    expect(fields[1].controller?.text, isEmpty);
    expect(fields[2].controller?.text, isEmpty);

    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '搜索').first).onPressed, isNotNull);
  });
}
