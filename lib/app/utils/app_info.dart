/// 应用信息常量（保持与 pubspec.yaml version 一致）。
///
/// 独立成文件供页面与备份等纯 Dart 服务共用；
/// 不依赖 package_info_plus（不在离线 pub cache，版本为硬编码常量）。
///
/// **版本号里的 `-lyricscrape.N` 是本分支的标记**，不是上游版本：
/// 基线是上游 `1.0.6`，后面挂的是本分支第 N 次改造发布。
/// 这样在「设置 → 关于」里一眼就能分清装的是原版还是本分支，
/// 而 `+9` 这个版本号继续沿用上游的递增序列，保证还能覆盖安装。
/// 改这里记得同步 `pubspec.yaml`，两处必须一致。
abstract class AppInfo {
  static const String name = 'FnMusic';
  static const String displayName = '飞牛音乐';
  static const String version = '1.0.6-lyricscrape.1+9';

  /// 本分支的标记，供 UI 决定是否显示「改造版」提示。
  static const String forkTag = 'lyricscrape';
}
