/// 用户授权的本地目录已经不可用：Android 的 SAF 授权被撤销，或 iOS 的安全作用域书签失效
/// （目录被删除、换了设备）。
///
/// 两个平台的本地来源适配器抛同一个类型，调用方（来源同步）只需要一句一致的提示：让用户重新选一次。
class FolderPermissionLostException implements Exception {
  const FolderPermissionLostException();

  @override
  String toString() => '本地目录授权已失效，请重新选择音乐文件夹';
}
