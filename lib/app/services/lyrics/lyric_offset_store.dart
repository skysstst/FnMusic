import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 每首歌的**手动歌词偏移**：`guid → 毫秒`。
///
/// ## 为什么单独一个文件，而不挂在 [LyricOrigin] 上
///
/// 偏移和「来源」是两件独立的事，耦合在一起会出两个问题：
/// - 音乐库自带的歌词（`origin == null`）同样可能整体早半拍或晚半拍，但它没有
///   来源记录可挂；
/// - 重新匹配（`rematchCurrentSong`）会连同来源记录一起清掉，而**用户的偏移
///   校正是他花了时间调出来的，不该因为换了一份歌词就被抹掉** —— 大概率新词也
///   需要同样的偏移。
///
/// ## 语义与 [LRC `offset:` 标签]一致
///
/// 正值 = 歌词整体**延后**。做法是把每行时间戳加上它，所以「歌词比歌早出现，
/// 要往后拖」就填正数。
///
/// ## 为什么不写进 LRC 文件再走解析器
///
/// 改缓存文件会污染「缓存 = 上游原样下载的内容」这个不变量：那份文件同时是
/// 「重新匹配时删掉重下」的对象，也是排查时对照上游的凭据。偏移是**本机的、
/// 用户的**判断，属于设置而不是内容。
///
/// [LRC `offset:` 标签]: ../../lyrics_parser.dart
class LyricOffsetStore {
  LyricOffsetStore._();

  static final LyricOffsetStore instance = LyricOffsetStore._();

  /// 记录文件名。`_` 开头且非 `.lrc`，不会被当成歌词文件计数。
  static const String fileName = '_offsets.json';

  /// 测试注入点：替换记录文件路径，避免单测依赖 path_provider 插件。
  @visibleForTesting
  static String? pathOverride;

  /// 偏移量的合理上限（±10 分钟）。
  ///
  /// 上限存在的意义是**拦住手滑**：滑杆是连续控件，一次误拖就能到几千毫秒，
  /// 而超过 10 分钟的偏移在音乐场景里基本等于「配错版本了」，那种情况该用
  /// 重新匹配而不是硬挪时间轴。写入时钳位，读出的值因此永远可信。
  static const int maxAbsMs = 600000;

  Map<String, int> _entries = <String, int>{};
  bool _loaded = false;

  /// 取这首歌的手动偏移；没有记录时返回 `null`（表示「没调过」而不是「调成 0」）。
  ///
  /// 区分这两者是有意义的：`0` 是用户的显式选择（他确认过对齐了），要在界面上
  /// 显示成「已归零」，而不是退化成「未调整」的外观。
  Future<int?> get(String guid) async {
    await _ensureLoaded();
    return _entries[guid];
  }

  Future<void> put(String guid, int ms) async {
    await _ensureLoaded();
    final int clamped = clampMs(ms);
    if (clamped == 0) {
      // 与「显式归零」等价的语义，落到删除上，避免文件里堆 0 值。
      if (_entries.remove(guid) != null) await _save();
      return;
    }
    _entries[guid] = clamped;
    await _save();
  }

  Future<void> remove(String guid) async {
    await _ensureLoaded();
    if (_entries.remove(guid) != null) await _save();
  }

  Future<void> clear() async {
    await _ensureLoaded();
    if (_entries.isEmpty) return;
    _entries = <String, int>{};
    await _save();
  }

  Future<int> count() async {
    await _ensureLoaded();
    return _entries.length;
  }

  /// 把任意整数钳到合法区间。
  static int clampMs(int ms) {
    if (ms > maxAbsMs) return maxAbsMs;
    if (ms < -maxAbsMs) return -maxAbsMs;
    return ms;
  }

  /// 仅供单测：丢弃内存状态，强制下次重新读文件。
  @visibleForTesting
  void resetForTest() {
    _entries = <String, int>{};
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
      final next = <String, int>{};
      decoded.forEach((key, value) {
        if (value is num) {
          final int ms = clampMs(value.toInt());
          if (ms != 0) next['$key'] = ms;
        }
      });
      _entries = next;
    } catch (_) {
      // 记录损坏就当空的 —— 它只影响对齐，不影响歌词本身。
    }
  }

  Future<void> _save() async {
    try {
      final file = File(await _resolvePath());
      await file.parent.create(recursive: true);
      await file.writeAsString(json.encode(_entries), flush: true);
    } catch (_) {
      // 写不进去就算了：下次播放会重新记录。
    }
  }

  /// 与 [LyricOriginStore] 放同一个目录（`lyrics/online/`）。
  ///
  /// 目录选择上它其实更像设置而非在线歌词，但跟随在线层有个实际好处：清空
  /// 在线歌词缓存时用户预期「把联网搞来的东西都清干净」，偏移跟着一起走不会
  /// 变成看不见的孤儿数据。
  Future<String> _resolvePath() async {
    final override = pathOverride;
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    return p.join(support.path, 'lyrics', 'online', fileName);
  }
}