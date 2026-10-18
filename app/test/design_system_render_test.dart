import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/design/components/album_card.dart';
import 'package:tingyu/design/components/artist_row.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/design/components/buttons.dart';
import 'package:tingyu/design/components/chips.dart';
import 'package:tingyu/design/components/track.dart';
import 'package:tingyu/design/components/command_palette.dart';
import 'package:tingyu/design/components/context_menu.dart';
import 'package:tingyu/design/components/detail_hero.dart';
import 'package:tingyu/design/components/playlist_card.dart';
import 'package:tingyu/design/components/sort_menu.dart';
import 'package:tingyu/design/layout/form_factor.dart';
import 'package:tingyu/design/theme.dart';
import 'package:tingyu/design/tokens/color.dart';
import 'package:tingyu/design/tokens/metrics.dart';
import 'package:tingyu/design/tokens/tokens.dart';

import 'support/pump.dart';

/// 把布局作用域与设计系统主题的接线固定下来：后续所有页面测试都依赖这套脚手架。
class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) {
    return Text(
      '${context.formFactor.name}|${context.metrics.rowHeight.toInt()}|'
      '${context.ty.colors == TyColors.light ? 'light' : 'dark'}|'
      '${context.ty.typography.bodyM.fontSize!.toInt()}|'
      '${context.traits.hover}',
      style: context.ty.typography.bodyM.copyWith(
        color: context.ty.colors.textPrimary,
      ),
    );
  }
}

void main() {
  _platformTraitsCoverage();
  _segmentedControlCoverage();

  testWidgets('三档尺寸解析出对应的外壳形态与行高', (WidgetTester tester) async {
    await pumpTyApp(tester, home: const _Probe(), size: TyTestSizes.phone);
    expect(find.textContaining('compact|56|light|15|'), findsOneWidget);

    await pumpTyApp(tester, home: const _Probe(), size: TyTestSizes.tablet);
    expect(find.textContaining('medium|52|light|15|'), findsOneWidget);

    await pumpTyApp(tester, home: const _Probe(), size: TyTestSizes.desktop);
    expect(find.textContaining('expanded|48|light|15|'), findsOneWidget);
  });

  testWidgets('深色主题把深浅色板一并带给组件', (WidgetTester tester) async {
    await pumpTyApp(
      tester,
      home: const _Probe(),
      size: TyTestSizes.desktop,
      brightness: Brightness.dark,
    );
    expect(find.textContaining('expanded|48|dark|15|'), findsOneWidget);
    final BuildContext context = tester.element(find.byType(_Probe));
    expect(TyTheme.of(context).isDark, isTrue);
  });

  testWidgets('紧凑密度只作用于桌面形态', (WidgetTester tester) async {
    await pumpTyApp(
      tester,
      home: const _Probe(),
      size: TyTestSizes.desktop,
      density: TyDensity.compact,
    );
    expect(find.textContaining('expanded|40|light|15|'), findsOneWidget);

    await pumpTyApp(
      tester,
      home: const _Probe(),
      size: TyTestSizes.phone,
      density: TyDensity.compact,
    );
    expect(find.textContaining('compact|56|light|15|'), findsOneWidget);
  });

  test('参考尺寸覆盖三档形态的边界', () {
    expect(metricsFor(TyTestSizes.phone).formFactor, FormFactor.compact);
    expect(metricsFor(TyTestSizes.tablet).formFactor, FormFactor.medium);
    expect(metricsFor(TyTestSizes.desktop).formFactor, FormFactor.expanded);
    expect(metricsFor(TyTestSizes.desktopMin).formFactor, FormFactor.expanded);
  });

  // ------------------------------------------------------------- B4 内容页组件

  group('B4 内容页组件', () {
    List<Override> coverOverrides() => <Override>[
      for (final String name in <String>['c1.jpg', 'c2.jpg'])
        coverFileProvider(name).overrideWith((Ref ref) async => null),
    ];

    testWidgets('专辑卡 / 艺人行 / 歌单卡 / 详情头图 / 排序菜单 / 命令面板三形态两主题渲染', (
      WidgetTester tester,
    ) async {
      for (final Size size in <Size>[
        TyTestSizes.phone,
        TyTestSizes.tablet,
        TyTestSizes.desktop,
      ]) {
        for (final Brightness brightness in Brightness.values) {
          await pumpTyApp(
            tester,
            size: size,
            brightness: brightness,
            overrides: coverOverrides(),
            home: const Scaffold(body: _B4Gallery()),
          );
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason: '$size / $brightness 渲染异常',
          );
          expect(find.text('海底'), findsOneWidget);
          expect(find.text('陈粒 · 2003 · 12 首'), findsOneWidget);
          expect(find.text('深夜歌单'), findsOneWidget);
          expect(find.text('新建歌单'), findsOneWidget);
          expect(find.text('如也'), findsOneWidget);
          expect(find.text('最近添加'), findsOneWidget);
          expect(find.text('歌曲'), findsOneWidget);
          expect(find.text('第一首'), findsOneWidget);
          expect(find.text('输入以搜索'), findsOneWidget);
        }
      }
    });

    testWidgets('命令面板方向键 + Enter 选中，Esc 关闭', (WidgetTester tester) async {
      TyPaletteEntry? picked;
      bool closed = false;
      await pumpTyApp(
        tester,
        size: TyTestSizes.desktop,
        home: Scaffold(
          body: TyCommandPalette(
            entries: const <TyPaletteEntry>[
              TyPaletteEntry(group: '歌曲', label: '第一首'),
              TyPaletteEntry(group: '歌曲', label: '第二首'),
              TyPaletteEntry(group: '专辑', label: '第一张'),
            ],
            onQueryChanged: (_) {},
            onSelected: (TyPaletteEntry entry) => picked = entry,
            onClosed: () => closed = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 分组头不参与选中：一次下移落到的必须是「第二首」，而不是「专辑」分组头。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(picked?.label, '第二首');

      // Enter 之后输入框会失焦，先把焦点点回来再按 Esc。
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(closed, isTrue);
    });

    testWidgets('排序菜单与右键菜单共用同一浮层', (WidgetTester tester) async {
      String? sorted;
      bool removed = false;
      await pumpTyApp(
        tester,
        size: TyTestSizes.desktop,
        home: Scaffold(
          body: Column(
            children: <Widget>[
              TySortMenu<String>(
                value: 'recent',
                direction: TySortDirection.descending,
                options: const <TySortOption<String>>[
                  TySortOption<String>(value: 'recent', label: '最近添加'),
                  TySortOption<String>(value: 'title', label: '标题'),
                ],
                onChanged: (String value) => sorted = value,
                onDirectionChanged: (_) {},
              ),
              Builder(
                builder: (BuildContext context) => TyButton(
                  label: '打开菜单',
                  variant: TyButtonVariant.secondary,
                  onPressed: () => TyContextMenu.show(
                    context,
                    position: const Offset(120, 120),
                    actions: <TyMenuAction>[
                      const TyMenuAction(label: '查看专辑'),
                      TyMenuAction(
                        label: '删除',
                        destructive: true,
                        onSelected: () => removed = true,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      await tester.tap(find.text('最近添加'));
      await tester.pumpAndSettle();
      // 当前项勾选 + 方向两项。
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('升序'), findsOneWidget);
      expect(find.text('降序'), findsOneWidget);
      await tester.tap(find.text('标题'));
      await tester.pumpAndSettle();
      expect(sorted, 'title');

      await tester.tap(find.text('打开菜单'));
      await tester.pumpAndSettle();
      expect(find.text('查看专辑'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(removed, isTrue);
    });
  });
}

/// 内容页组件画廊：把新增组件放进同一个可滚动页面，覆盖三形态两主题的渲染。
class _B4Gallery extends StatelessWidget {
  const _B4Gallery();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: TySpace.x16,
            runSpacing: TySpace.x16,
            children: <Widget>[
              TyAlbumCard(
                title: '海底',
                subtitle: '陈粒 · 2003 · 12 首',
                coverSeed: 'sea',
                width: 160,
                onTap: () {},
                onPlay: () {},
                trailing: const Icon(Icons.more_horiz),
              ),
              TyPlaylistCard(
                title: '深夜歌单',
                subtitle: '12 首',
                coverPaths: const <String>['c1.jpg', 'c2.jpg'],
                width: 160,
                onTap: () {},
                onPlay: () {},
              ),
              TyNewPlaylistCard(width: 160, onTap: () {}),
            ],
          ),
          TyArtistRow(name: '陈粒', subtitle: '3 张专辑 · 28 首', onTap: () {}),
          TyDetailHero(
            title: '如也',
            eyebrow: '专辑',
            meta: '陈粒 · 2015 · 12 首',
            coverSeed: 'ruye',
            actions: <Widget>[TyButton(label: '播放', onPressed: () {})],
          ),
          TyDetailHero(
            title: '陈粒',
            eyebrow: '艺人',
            coverShape: TyDetailHeroShape.circle,
          ),
          Padding(
            padding: const EdgeInsets.all(TySpace.x16),
            child: TySortMenu<String>(
              value: 'recent',
              direction: TySortDirection.descending,
              options: const <TySortOption<String>>[
                TySortOption<String>(value: 'recent', label: '最近添加'),
                TySortOption<String>(value: 'title', label: '标题'),
              ],
              onChanged: (_) {},
              onDirectionChanged: (_) {},
            ),
          ),
          TyCommandPalette(
            entries: const <TyPaletteEntry>[
              TyPaletteEntry(
                group: '歌曲',
                label: '第一首',
                subtitle: '陈粒',
                hint: 'Enter',
              ),
              TyPaletteEntry(group: '专辑', label: '第一张'),
            ],
            onQueryChanged: (_) {},
            onSelected: (_) {},
          ),
          const TyCommandPalette(
            entries: <TyPaletteEntry>[],
            onQueryChanged: _ignore,
            onSelected: _ignoreEntry,
          ),
        ],
      ),
    );
  }
}

void _ignore(String _) {}

void _ignoreEntry(TyPaletteEntry _) {}

/// 平台只影响交互语汇（hover / 右键 / 长按 / 滚动条 / 主修饰键）。
/// 真机只能在 Windows 上跑，所以**触控平台的分支必须靠测试覆盖**：否则
/// 「触控下次要操作常显、长按打开同一个菜单」这类分支永远没人跑。
void _platformTraitsCoverage() {
  testWidgets('触控平台：卡片的次要操作不靠 hover 也能看到、能点', (WidgetTester tester) async {
    await withTargetPlatform(TargetPlatform.android, () async {
      bool tapped = false;
      await pumpTyApp(
        tester,
        home: Scaffold(
          body: TyAlbumCard(
            title: '叶惠美',
            subtitle: '周杰伦 · 2003 · 12 首',
            width: 180,
            trailing: TyIconAction(
              icon: Icons.more_horiz,
              semanticLabel: '更多',
              tooltip: '更多',
              onPressed: () => tapped = true,
            ),
          ),
        ),
        size: TyTestSizes.phone,
      );

      expect(layoutScopeOf(tester).traits.touchPrimary, isTrue);
      // 没有 hover 事件注入：触控形态下它必须已经可见、可点。
      await tester.tap(find.byTooltip('更多'));
      expect(tapped, isTrue, reason: '触控形态下卡片的 trailing 必须常显可点');
    });
  });

  testWidgets('触控平台：曲目行的 ♥ / ⋯ 不靠 hover 也能看到', (WidgetTester tester) async {
    await withTargetPlatform(TargetPlatform.android, () async {
      final Track track = Track(
        id: 't1',
        sourceId: 's1',
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 200,
        fileFormat: 'mp3',
        filePathOrUrl: '/music/t1.mp3',
        fileSize: 1,
        isFavorite: false,
        dateAdded: DateTime.utc(2026, 9, 1),
        playCount: 0,
      );
      await pumpTyApp(
        tester,
        home: Scaffold(
          body: TyTrackRow(
            track: track,
            isPlaying: false,
            onToggleFavorite: () {},
            onMore: () {},
          ),
        ),
        size: TyTestSizes.phone,
      );

      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
    });
  });

  testWidgets('桌面平台：hover 语汇与宏/右键能力齐备，触控能力关闭', (WidgetTester tester) async {
    await withTargetPlatform(TargetPlatform.macOS, () async {
      await pumpTyApp(tester, home: const _Probe(), size: TyTestSizes.desktop);

      final PlatformTraits traits = layoutScopeOf(tester).traits;
      expect(traits.hover, isTrue);
      expect(traits.rightClickMenus, isTrue);
      expect(traits.touchPrimary, isFalse);
      expect(traits.primaryModifierIsMeta, isTrue);
      expect(traits.keyboardShortcuts, isTrue);
    });
  });
}

/// 分段控件的宽度纪律：段数少时不许铺满整行（否则变成一条空槽），
/// 窄屏则必须铺满（它就是那一层的导航）。
void _segmentedControlCoverage() {
  testWidgets('分段控件：桌面限宽 480，窄屏铺满', (WidgetTester tester) async {
    Future<void> pump(Size size) => pumpTyApp(
      tester,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TySegmentedControl(
            segments: const <String>['歌曲', '专辑'],
            index: 0,
            onChanged: (_) {},
          ),
        ),
      ),
      size: size,
    );

    // 分段控件本体在 Align 里面：Align 仍然占满整行，量的是它内部的那个槽。
    double controlWidth() => tester
        .getSize(
          find
              .descendant(
                of: find.byType(TySegmentedControl),
                matching: find.byType(Container),
              )
              .first,
        )
        .width;

    await pump(const Size(1440, 900));
    expect(
      controlWidth(),
      lessThanOrEqualTo(TySegmentedControl.defaultMaxWidth + 1),
    );

    await pump(const Size(412, 915));
    expect(
      controlWidth(),
      closeTo(412 - 40, 1),
      reason: '窄屏（比上限窄）时分段控件应当铺满可用宽度',
    );
  });
}
