import 'lyric_query.dart';

/// 命中歌词的同步粒度。
enum LyricFormat {
  /// 无时间轴的纯文本（本项目不使用，保留以便将来兼容）。
  plain,

  /// 整行同步 LRC。
  lineSynced,

  /// 逐字同步（增强型 LRC，渲染层直接走卡拉OK 逐字）。
  wordSynced,
}

/// 一个歌词源的命中结果。
class LyricFetchResult {
  const LyricFetchResult({
    required this.content,
    required this.sourceId,
    required this.format,
    this.matchedTitle,
    this.matchedArtist,
    this.matchedDurationMs,
  });

  /// 可直接喂给 `LyricsParser.buildModelFromRaw()` 的 LRC 文本。
  final String content;

  /// 产出该结果的源 id。
  final String sourceId;

  final LyricFormat format;

  /// 便于排查「匹配到了别的歌」——记录源端返回的歌名/歌手/时长。
  final String? matchedTitle;
  final String? matchedArtist;
  final int? matchedDurationMs;
}

/// 源被限流。路由层收到后**不再继续重试该源**，并按 [retryAfter] 进入冷却。
class LyricRateLimitedException implements Exception {
  LyricRateLimitedException(this.sourceId, {this.retryAfter});

  final String sourceId;
  final Duration? retryAfter;

  @override
  String toString() =>
      'LyricRateLimitedException($sourceId, retryAfter=$retryAfter)';
}

/// 网络错误 / 解析错误 / 服务端异常。路由层收到后继续尝试下一个源。
class LyricSourceException implements Exception {
  LyricSourceException(this.sourceId, this.message);

  final String sourceId;
  final String message;

  @override
  String toString() => 'LyricSourceException($sourceId): $message';
}

/// 源**暂时**不可用（典型场景：首次索引还没下载完）。
///
/// 与「真的没有这首歌」必须区分开：路由层收到后只跳过该源并**照常尝试其他源**，
/// 但**不得**把该源写进失败记忆——否则一次冷启动的时序问题会让这个源被拉黑十几天。
class LyricSourceNotReadyException implements Exception {
  LyricSourceNotReadyException(this.sourceId, this.message);

  final String sourceId;
  final String message;

  @override
  String toString() => 'LyricSourceNotReadyException($sourceId): $message';
}

/// 连通性自检的结果状态。
enum LyricProbeStatus {
  /// 拿到了歌词 —— 渠道确认可用。
  ok,

  /// 渠道能连上、也正常应答，但探针歌没查到词。
  ///
  /// 探针歌是**这个源一定有**的大众歌，所以出现这个状态基本意味着渠道改版了，
  /// 而不是「这首歌没有」——这正是设置页要做连通性测试的意义。
  noResult,

  /// 被限流。
  rateLimited,

  /// 暂时不可用（如首次索引还没下完）。
  notReady,

  /// 连不上 / 报错。
  failed,
}

/// 一次连通性自检的结果。
class LyricProbeResult {
  const LyricProbeResult({
    required this.sourceId,
    required this.status,
    required this.message,
    required this.elapsed,
    this.format,
    this.chars,
  });

  final String sourceId;
  final LyricProbeStatus status;

  /// 给人看的一句话结论。
  final String message;
  final Duration elapsed;

  /// 命中时的歌词粒度与字数（`ok` 时才有）。
  final LyricFormat? format;
  final int? chars;

  bool get ok => status == LyricProbeStatus.ok;
}

/// 在线歌词源。实现方只管「查询 → 返回 LRC 文本」，不负责缓存与渲染。
///
/// 约定：
/// - 命中 → 返回 [LyricFetchResult]
/// - 明确没有（404 / 无该歌）→ 返回 `null`
/// - 被限流 → 抛 [LyricRateLimitedException]
/// - 暂时不可用 → 抛 [LyricSourceNotReadyException]
/// - 其他失败 → 抛 [LyricSourceException]
///
/// 路由层依赖这个约定决定「继续下一个源」「跳过该源」「跳过但不记失败」。
abstract class LyricSource {
  const LyricSource();

  /// 稳定 id，同时用作设置项的持久化键，**不要随意改名**。
  String get id;

  /// 设置页展示名。
  String get displayName;

  /// 该源是否需要联网以外的前置条件（如首次索引下载），用于设置页提示。
  String get description;

  /// 默认是否启用。
  bool get enabledByDefault;

  /// 该源是否能在「实在找不到带时间轴的歌词」时，退回提供无时间轴的纯文本。
  ///
  /// 只有路由层的第一轮全部落空后，才会带 `allowPlain: true` 再问一次这些源。
  /// 纯文本歌词 FnMusic 也能显示（解析器会把文本按行均摊到时长上），
  /// 属于「有总比没有强」的最后手段。
  bool get supportsPlain => false;

  /// 单次请求的超时上限（整源级别，不是单个 HTTP 请求）。
  Duration get timeout => const Duration(seconds: 12);

  /// 连通性自检用的「探针歌曲」。
  ///
  /// 设置页的「测试」按钮拿它去问这个源。**探针歌必须是这个源一定有的大众歌**，
  /// 否则测出「没结果」时分不清是「渠道挂了」还是「这首歌太偏」——
  /// 那就白测了。中文源统一用《晴天》（周杰伦），西文源用对应语种的大众歌。
  LyricQuery get probeQuery => const LyricQuery(
        title: '晴天',
        artist: '周杰伦',
        durationMs: 269000,
      );

  Future<LyricFetchResult?> fetch(LyricQuery query, {bool allowPlain = false});
}
