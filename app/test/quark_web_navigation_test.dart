import 'package:flutter_test/flutter_test.dart';
import 'package:tingyu/sources/quark/quark_web_navigation.dart';

void main() {
  test('https 原样通过', () {
    expect(
      resolveQuarkWebNavigation('https://uop.quark.cn/cas/custom/login')?.toString(),
      'https://uop.quark.cn/cas/custom/login',
    );
  });

  test('intent 优先用 browser_fallback_url', () {
    const String url =
        'intent://uop.quark.cn/cas/callback#Intent;scheme=https;package=com.quark.browser;'
        'S.browser_fallback_url=https%3A%2F%2Fuop.quark.cn%2Fcas%2Fcustom%2Flogin%3Fdisplay%3Dmobile;end';
    expect(
      resolveQuarkWebNavigation(url)?.toString(),
      'https://uop.quark.cn/cas/custom/login?display=mobile',
    );
  });

  test('intent 无 fallback 时用 scheme + host', () {
    const String url =
        'intent://passport.quark.cn/v2/login#Intent;scheme=https;package=com.quark.browser;end';
    expect(
      resolveQuarkWebNavigation(url)?.toString(),
      'https://passport.quark.cn/v2/login',
    );
  });

  test('纯 app scheme 没有回退地址则放弃', () {
    expect(resolveQuarkWebNavigation('quark://login'), isNull);
    expect(
      resolveQuarkWebNavigation(
        'intent://scan#Intent;scheme=quark;package=com.quark.browser;end',
      ),
      isNull,
    );
  });
}
