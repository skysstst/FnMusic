import 'lyric_query.dart';

/// 判定结果：`null` 表示这首歌值得送去刮削；否则给出不该送的理由。
class LyricSkipReason {
  const LyricSkipReason(this.code, this.label);

  /// 稳定的机器码，便于日志与统计。
  final String code;

  /// 给人看的一句话。
  final String label;

  @override
  String toString() => '$code($label)';
}

/// 刮削资格过滤器：**先过滤，再联网**。
///
/// 这个曲库是主播的直播录音合集（实测 11,425 首，其中 1,294 首时长超过 8 分钟
/// 全是直播回放）。把这些原样丢给歌词接口有三个坏处：
/// 1. 白跑请求，还会加速触发各源的限流；
/// 2. 拿回来的往往是同名的**别的歌**（`日常聊天` 之类根本不在任何歌词库里）；
/// 3. 用户在设置页看到「已刮削 N 首」时，N 会被这些噪音灌水。
///
/// 所以这里把「不可能有歌词」和「用户明确说不要」的两类先挡掉。
/// 规则与 `tools/_normalize.py` 同源，改一边记得改另一边。
class LyricEligibility {
  const LyricEligibility._();

  /// 短于这个时长视为片段（前奏试唱、清唱片段）。
  static const int minDurationMs = 60 * 1000;

  /// 超过这个时长视为直播 / 播客回放，不是单曲。
  static const int maxDurationMs = 8 * 60 * 1000;

  /// 清洗后的标题超过这个长度且带句读 → 判为直播话题。
  static const int maxTitleLength = 24;

  /// 判断是否**跳过**刮削。返回 `null` 表示可以刮。
  ///
  /// [title] 传原始标题即可，内部会先清洗再判断。
  static LyricSkipReason? check({
    required String title,
    required String? artist,
    required int? durationMs,
  }) {
    final raw = title.trim();
    if (raw.isEmpty) {
      return const LyricSkipReason('empty_title', '标题为空');
    }

    final ms = durationMs ?? 0;
    if (ms > 0 && ms < minDurationMs) {
      return const LyricSkipReason('too_short', '片段过短（不到 1 分钟）');
    }
    if (ms > maxDurationMs) {
      return const LyricSkipReason('too_long', '超长录音（超过 8 分钟，直播/播客回放）');
    }

    final half = LyricTextNorm.toHalfWidth(raw);
    final lower = half.toLowerCase();

    for (final w in LyricTextNorm.noLyricWords) {
      if (lower.contains(w)) {
        return const LyricSkipReason('instrumental', '伴奏 / 纯音乐，没有词可刮');
      }
    }
    for (final w in LyricTextNorm.acappellaWords) {
      if (lower.contains(w)) {
        return const LyricSkipReason('acappella', '清唱版本');
      }
    }

    final hasDash = half.contains(RegExp(r'[-–—－]'));
    if (hasDash) {
      for (final w in LyricTextNorm.broadcastWords) {
        if (half.contains(w)) {
          return LyricSkipReason('broadcast', '直播 / 播客栏目（$w）');
        }
      }
    } else if (half.length >= 14 &&
        LyricTextNorm.sentenceMark.hasMatch(half)) {
      return const LyricSkipReason('broadcast_topic', '直播话题（一句话，不是歌名）');
    }

    final clean = LyricTextNorm.cleanTitle(raw, artist: artist);
    if (clean.isEmpty) {
      return const LyricSkipReason('empty_after_clean', '清洗后没有剩下歌名');
    }
    if (LyricTextNorm.selfName.hasMatch(clean)) {
      return const LyricSkipReason('self_topic', '直播话题（标题里带着主播名）');
    }
    if (clean.length > maxTitleLength &&
        LyricTextNorm.sentenceMark.hasMatch(clean)) {
      return const LyricSkipReason('long_topic', '标题过长且像话题，不是歌名');
    }
    return null;
  }
}
