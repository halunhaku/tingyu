/// 把夸克登录页发出的跳转收成 WebView 能继续走的 http(s) 地址。
///
/// 手机登录页点「登录」时常发 `intent://…` 想拉起夸克 App。WebView 打不开这种
/// scheme，`url_launcher` 也解析不了，表现为第一次点击没反应；二次点击会打到
/// 已经作废的一次性登录态，页面提示无效。
///
/// 有 `S.browser_fallback_url` 或 `scheme=https` 时，改在当前 WebView 里继续。
Uri? resolveQuarkWebNavigation(String url) {
  final String trimmed = url.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final Uri? uri = Uri.tryParse(trimmed);
  final String scheme = (uri?.scheme ?? '').toLowerCase();
  if (scheme == 'http' || scheme == 'https') {
    return uri;
  }
  if (scheme == 'intent' || trimmed.startsWith('intent:')) {
    return parseAndroidIntentUrl(trimmed);
  }
  return null;
}

/// 解析 Android `intent://host/path#Intent;scheme=https;S.browser_fallback_url=…;end`。
Uri? parseAndroidIntentUrl(String url) {
  final Match? fallback = RegExp(
    r'S\.browser_fallback_url=([^;]+)',
  ).firstMatch(url);
  if (fallback != null) {
    final Uri? decoded = Uri.tryParse(Uri.decodeComponent(fallback.group(1)!));
    if (decoded != null &&
        (decoded.scheme == 'http' || decoded.scheme == 'https')) {
      return decoded;
    }
  }

  final String? intentScheme = RegExp(r';scheme=([^;]+);').firstMatch(url)?.group(1);
  if (intentScheme != 'http' && intentScheme != 'https') {
    return null;
  }
  const String prefix = 'intent://';
  if (!url.startsWith(prefix)) {
    return null;
  }
  final String path = url.substring(prefix.length).split('#').first;
  return Uri.tryParse('$intentScheme://$path');
}
