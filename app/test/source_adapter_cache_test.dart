import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/app/providers.dart';
import 'package:tingyu/app/source_adapters.dart';
import 'package:tingyu/data/db/database.dart';
import 'package:tingyu/data/secure_store.dart';

import 'support/test_support.dart';

/// 适配器缓存的三条约定：
/// 1. 同一来源重复取用拿到同一个实例（夸克的直链缓存挂在实例上，重建等于清空它）；
/// 2. 来源行里参与构造的字段变了要重建；
/// 3. 凭据写入过（重新登录 / 改密码）也要重建；构造失败不留缓存。
void main() {
  // 适配器构造会读系统安全存储（平台通道），先备好 test binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  // 未签名的开发构建下，安全存储会回退到"应用支持目录 + 0600 文件"；
  // 测试里把这条路径指到临时目录，凭据读写才能真的走完一遍。
  late Directory supportDir;
  setUp(() async {
    supportDir = await Directory.systemTemp.createTemp('tingyu_credentials_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => call.method ==
                  'getApplicationSupportDirectory'
              ? supportDir.path
              : null,
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (supportDir.existsSync()) {
      await supportDir.delete(recursive: true);
    }
  });

  MusicSource source({
    String id = 's1',
    String url = 'https://dav.example.com/dav/',
    String username = 'u',
    String folder = '',
  }) => MusicSource(
    id: id,
    name: 'WebDAV',
    kind: 'webdav',
    webdavUrl: url,
    webdavUsername: username,
    quarkFolderFid: folder,
    syncStatus: '未同步',
    trackCount: 0,
  );

  ProviderContainer containerWith(TingyuDatabase database) {
    final ProviderContainer container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('同一来源重复取用返回同一个适配器实例', () async {
    final TingyuDatabase database = openTestDatabase();
    addTearDown(database.close);
    final SourceAdapterCache cache = containerWith(
      database,
    ).read(sourceAdapterCacheProvider);

    final Object first = await cache.of(source());
    final Object second = await cache.of(source());

    expect(identical(first, second), isTrue);
  });

  test('来源配置变化或凭据写入后重建适配器', () async {
    final TingyuDatabase database = openTestDatabase();
    addTearDown(database.close);
    final SourceAdapterCache cache = containerWith(
      database,
    ).read(sourceAdapterCacheProvider);

    final Object first = await cache.of(source());

    // 换了 URL：旧实例里的 rootUri 已经不对，必须重建。
    final Object afterUrlChange = await cache.of(
      source(url: 'https://other.example.com/dav/'),
    );
    expect(identical(first, afterUrlChange), isFalse);

    // 重新登录 / 改密码：新密码写进安全存储，缓存的 Basic 头必须跟着换。
    await SecureStore().writeWebDavPassword('s1', 'new-password');
    final Object afterCredentialChange = await cache.of(
      source(url: 'https://other.example.com/dav/'),
    );
    expect(identical(afterUrlChange, afterCredentialChange), isFalse);
  });

  test('不同来源各自缓存', () async {
    final TingyuDatabase database = openTestDatabase();
    addTearDown(database.close);
    final SourceAdapterCache cache = containerWith(
      database,
    ).read(sourceAdapterCacheProvider);

    final Object a = await cache.of(source(id: 's1'));
    final Object b = await cache.of(source(id: 's2'));

    expect(identical(a, b), isFalse);
    // 取用 s2 不会把 s1 挤掉。
    expect(identical(await cache.of(source(id: 's1')), a), isTrue);
  });

  test('构造失败不写进缓存：下一次取用会重新尝试构造', () async {
    final TingyuDatabase database = openTestDatabase();
    addTearDown(database.close);
    final SourceAdapterCache cache = containerWith(
      database,
    ).read(sourceAdapterCacheProvider);

    final MusicSource broken = source(url: 'http://[broken');

    Object? firstError;
    try {
      await cache.of(broken);
    } on Object catch (error) {
      firstError = error;
    }
    expect(firstError, isNotNull);

    Object? secondError;
    try {
      await cache.of(broken);
    } on Object catch (error) {
      secondError = error;
    }
    // 复用同一个失败的 Future 会得到同一个异常对象；重新构造才是新的实例。
    expect(secondError, isNotNull);
    expect(identical(firstError, secondError), isFalse);
  });

  test('ofId 按来源 id 取适配器，来源不存在时明确抛错', () async {
    final TingyuDatabase database = openTestDatabase();
    addTearDown(database.close);
    final ProviderContainer container = containerWith(database);
    await container
        .read(sourceRepositoryProvider)
        .upsert(
          MusicSourcesCompanion.insert(
            id: 's1',
            name: 'WebDAV',
            kind: 'webdav',
            webdavUrl: const Value<String>('https://dav.example.com/dav/'),
            webdavUsername: const Value<String>('u'),
          ),
        );
    final SourceAdapterCache cache = container.read(sourceAdapterCacheProvider);

    final Object adapter = await cache.ofId('s1');
    expect(identical(await cache.ofId('s1'), adapter), isTrue);
    await expectLater(cache.ofId('nope'), throwsStateError);

    cache.evict('s1');
    expect(identical(await cache.ofId('s1'), adapter), isFalse);
  });
}
