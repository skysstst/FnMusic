import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 一份**在线歌词**的来历。
///
/// 解决的是「屏幕上这词是哪来的」这个原来回答不了的问题：`OnlineLyricSource`
/// 内部一直知道命中了哪个渠道、配到了源侧的哪首歌，但只打进了 debug 日志。
/// 现在把它连同「跟曲库这首歌的时长差」一起记下来，播放页可以直接显示。
///
/// 为什么连 `matchedTitle` / `matchedArtist` 也存：这个曲库的歌词**全部靠跨歌手
/// 采纳**（曲库里的歌手是翻唱者，歌词库里只有原唱条目）。所以「配到了谁的版本」
/// 是判断这份词到底对不对的关键线索，比「来自哪个渠道」更有信息量。
class LyricOrigin {
  const LyricOrigin({
    required this.sourceId,
    required this.at,
    this.matchedTitle,
    this.matchedArtist,
    this.matchedDurationMs,
    this.deltaMs,
    this.format,
  });

  /// 产出这份歌词的渠道 id（`qqmusic` / `kugou` / …）。
  final String sourceId;

  /// 记录时间。
  final DateTime at;

  /// 渠道侧命中的歌名。
  final String? matchedTitle;

  /// 渠道侧命中的歌手 —— 跨歌手场景下它**不是**曲库里的歌手。
  final String? matchedArtist;

  /// 渠道侧那首歌的时长（毫秒）。
  final int? matchedDurationMs;

  /// 与曲库里这首歌的时长差（毫秒，绝对值）。
  final int? deltaMs;

  /// 歌词粒度（`wordSynced` / `lineSynced` / `plain`）。
  final String? format;

  Map<String, Object?> toJson() => <String, Object?>{
        'source': sourceId,
        'at': at.millisecondsSinceEpoch,
        if (matchedTitle != null) 'mt': matchedTitle,
        if (matchedArtist != null) 'ma': matchedArtist,
        if (matchedDurationMs != null) 'md': matchedDurationMs,
        if (deltaMs != null) 'delta': deltaMs,
        if (format != null) 'fmt': format,
      };

  /// 解析一条记录；结构不对或时间戳缺失时返回 `null`（当作没记录）。
  static LyricOrigin? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final source = raw['source'];
    final at = raw['at'];
    if (source is! String || source.isEmpty) return null;
    if (at is! int) return null;
    return LyricOrigin(
      sourceId: source,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      matchedTitle: raw['mt'] as String?,
      matchedArtist: raw['ma'] as String?,
      matchedDurationMs: (raw['md'] as num?)?.toInt(),
      deltaMs: (raw['delta'] as num?)?.toInt(),
      format: raw['fmt'] as String?,
    );
  }
}

/// 在线歌词来源记录：`guid → 来历`。
///
/// 落成一个 JSON 文件而不是 SharedPreferences，理由与负缓存相同：条目会随曲库
/// 规模增长，而 SharedPreferences 在 Android 上会被整体加载进内存。
///
/// 文件放在**在线层目录里面**（`lyrics/online/_origins.json`）是刻意的：
/// 「这份歌词的来历」本来就属于在线歌词这一层。这样清空在线歌词缓存时，
/// 来历记录会跟着一起消失，不会留下一堆指向已删歌词的孤儿记录。
class LyricOriginStore {
  LyricOriginStore._();

  static final LyricOriginStore instance = LyricOriginStore._();

  /// 记录文件名。以 `_` 开头且不是 `.lrc`，因此不会被当成一份歌词文件计数。
  static const String fileName = '_origins.json';

  /// 测试注入点：替换记录文件路径，避免单测依赖 path_provider 插件。
  @visibleForTesting
  static String? pathOverride;

  Map<String, LyricOrigin> _entries = <String, LyricOrigin>{};
  bool _loaded = false;

  Future<LyricOrigin?> get(String guid) async {
    await _ensureLoaded();
    return _entries[guid];
  }

  Future<void> put(String guid, LyricOrigin origin) async {
    await _ensureLoaded();
    _entries[guid] = origin;
    await _save();
  }

  Future<void> remove(String guid) async {
    await _ensureLoaded();
    if (_entries.remove(guid) != null) await _save();
  }

  Future<void> clear() async {
    await _ensureLoaded();
    if (_entries.isEmpty) return;
    _entries = <String, LyricOrigin>{};
    await _save();
  }

  Future<int> count() async {
    await _ensureLoaded();
    return _entries.length;
  }

  /// 仅供单测：丢弃内存状态，强制下次重新读文件。
  @visibleForTesting
  void resetForTest() {
    _entries = <String, LyricOrigin>{};
    _loaded = false;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = File(await _resolvePath());
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = json.decode(raw);
      if (decoded is! Map) return;
      final next = <String, LyricOrigin>{};
      decoded.forEach((key, value) {
        final origin = LyricOrigin.fromJson(value);
        if (origin != null) next['$key'] = origin;
      });
      _entries = next;
    } catch (_) {
      // 记录损坏就当空的 —— 它只影响「来源」这一行提示，不影响歌词本身。
    }
  }

  Future<void> _save() async {
    try {
      final file = File(await _resolvePath());
      await file.parent.create(recursive: true);
      final data = <String, Object?>{};
      _entries.forEach((key, origin) {
        data[key] = origin.toJson();
      });
      await file.writeAsString(json.encode(data), flush: true);
    } catch (_) {
      // 写不进去就算了：下次播放会重新记录。
    }
  }

  Future<String> _resolvePath() async {
    final override = pathOverride;
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    return p.join(support.path, 'lyrics', 'online', fileName);
  }
}
