import 'package:xml/xml.dart';

/// 一条 PROPFIND 响应条目，对齐旧版 `WebDAVItem`。
class WebDavItem {
  const WebDavItem({
    required this.href,
    this.displayName,
    this.isDirectory = false,
    this.contentLength = 0,
    this.etag,
    this.lastModified,
  });

  /// 服务器原样返回的 href（未做解析/编码处理）。
  final String href;

  /// `displayname`；元素缺失为 `null`，元素为空串则为 `''`。
  final String? displayName;

  /// `resourcetype` 里出现 `collection` 即为目录。
  final bool isDirectory;

  final int contentLength;

  /// 已去掉首尾引号的 `getetag`。
  final String? etag;

  final String? lastModified;
}

/// PROPFIND `multistatus` 解析，对齐旧版 `WebDAVXMLParser.swift`。
///
/// 与旧版的差异只有解析器本身：Swift 用 `XMLParser` 流式解析、按元素名 `hasSuffix`
/// 匹配；这里用 `package:xml` 一次性建树，按 `XmlName.local` 匹配（前缀大小写、
/// 是否声明命名空间都不影响），元素文本取 `innerText` 后 trim（旧版 `currentText`
/// 同理，是元素内的全部文本节点）。两个实现都是「同一响应里后出现的元素覆盖先出现的」。
class WebDavXmlParser {
  const WebDavXmlParser();

  static const String _response = 'response';
  static const String _collection = 'collection';
  static const String _href = 'href';
  static const String _displayName = 'displayname';
  static const String _contentLength = 'getcontentlength';
  static const String _etag = 'getetag';
  static const String _lastModified = 'getlastmodified';

  /// 标量规则与旧版一致：引号（且仅引号）从 etag 两端剥离。
  static final RegExp _surroundingQuotes = RegExp(r'^"+|"+$');

  /// 解析失败时抛 [XmlException]（旧版 `XMLParser` 只是返回空数组，不抛错）。
  List<WebDavItem> parse(String xml) {
    final List<WebDavItem> items = <WebDavItem>[];
    for (final XmlNode node in XmlDocument.parse(xml).descendants) {
      if (node is! XmlElement || node.name.local != _response) {
        continue;
      }
      final WebDavItem? item = _parseResponse(node);
      if (item != null) {
        items.add(item);
      }
    }
    return items;
  }

  /// href 为空（或全为空白）的响应条目按旧版直接丢弃。
  WebDavItem? _parseResponse(XmlElement response) {
    String href = '';
    String? displayName;
    int contentLength = 0;
    String? etag;
    String? lastModified;
    bool isDirectory = false;

    for (final XmlNode node in response.descendants) {
      if (node is! XmlElement) {
        continue;
      }
      switch (node.name.local) {
        case _href:
          href = _text(node);
        case _displayName:
          displayName = _text(node);
        case _contentLength:
          contentLength = int.tryParse(_text(node)) ?? 0;
        case _etag:
          etag = _text(node).replaceAll(_surroundingQuotes, '');
        case _lastModified:
          lastModified = _text(node);
        case _collection:
          isDirectory = true;
        default:
          // getcontenttype 等字段旧版也没用上，直接忽略。
          break;
      }
    }

    if (href.isEmpty) {
      return null;
    }
    return WebDavItem(
      href: href,
      displayName: displayName,
      isDirectory: isDirectory,
      contentLength: contentLength,
      etag: etag,
      lastModified: lastModified,
    );
  }

  static String _text(XmlElement element) => element.innerText.trim();
}
