import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/song_state.dart';
import 'sources/amll_source.dart';
import 'sources/kugou_source.dart';
import 'sources/kuwo_source.dart';
import 'sources/lrclib_source.dart';
import 'sources/lyric_eligibility.dart';
import 'sources/lyric_query.dart';
import 'sources/lyric_source.dart';
import 'sources/netease_source.dart';
import 'sources/qqmusic_source.dart';

/// 歌词刮削路由器：多源顺序尝试 + 兜底。
///
/// 设计要点：
/// 1. **先过滤再联网**：[LyricEligibility] 把直播回放 / 播客 / 伴奏 / 清唱
///    挡在门外。曲库里这类占了 15%，原样丢给接口既白烧请求又加速触发限流。
/// 2. **顺序降级**：按 [_sourceOrder] 依次尝试，任一源命中即返回；
/// 3. **两轮策略**：第一轮只接受「带时间轴」的歌词（整行或逐字）；全部落空后
///    第二轮才允许退到无时间轴的纯文本（只有 [LyricSource.supportsPlain] 的源参与）；
/// 4. **限流纪律**：同一源两次请求之间强制间隔 [_minInterval]，被限流
///    （[LyricRateLimitedException]）后按 `Retry-After` 进入冷却，本轮跳过该源；
/// 5. **失败记忆**：某首歌全部启用源都试过且无结果时写入负缓存，默认
///    [_missTtl] 内不再重复联网（避免每次播放都白跑几个请求），
///    命中后会立即清除记录；
/// 6. **单飞**：同一首歌的并发请求合并为一次；
/// 7. **不冤枉源**：源抛 [LyricSourceNotReadyException]（如 AMLL 索引还没下完）
///    或被限流时，只跳过、**不写失败记忆**，否则一次冷启动就会把这个源
///    拉黑十几天。
///
/// 本类只负责「取到文本」，**写缓存与渲染仍由 [LyricsService] / [LyricsRepository]
/// 负责**，职责边界与原有代码保持一致。
class OnlineLyricSource {
  OnlineLyricSource._();

  static final OnlineLyricSource instance = OnlineLyricSource._();

  /// 尝试顺序即优先级。
  ///
  /// 排序依据是**实测召回率 × 覆盖语种**，不是「谁名气大」：
  /// - QQ 音乐 91%、酷狗 94%、酷我 86% —— 中文翻唱曲库的三个主力；
  /// - 网易云 ~90% 但**接口极易限流**（把限流包在 HTTP 200 里），挪到中文源第三位；
  /// - LRCLIB 是欧美公共库，中文覆盖低、限流最紧，只做西文兜底；
  /// - AMLL 是**逐字**专用，命中率最低且首次要下 6 MB 索引，放最后。
  ///
  /// 想调顺序就在这一处改，别在别处再写一份「源列表」。
  static final List<LyricSource> _sourceOrder = <LyricSource>[
    QqMusicSource(),
    KugouSource(),
    KuwoSource(),
    NeteaseSource(),
    LrclibSource(),
    AmllTtmlDbSource(),
  ];

  static const Duration _minInterval = Duration(milliseconds: 350);
  static const Duration _missTtl = Duration(days: 14);

  /// 负缓存的结构版本。
  ///
  /// 只要**匹配策略**变了（归一化规则、打分逻辑、源的增删），旧的「未命中」
  /// 结论就不再可信 —— 修好了匹配却还被十几天的旧记录挡在门外，是最难排查的
  /// 一类「怎么还是搜不到」。所以策略一改就抬版本号，[store.load] 会直接丢弃
  /// 低版本条目，让每首歌重新联网试一次。
  /// v1 → v2：繁转简、歌手降级为加分项、QQ 换用 search_for_qq_cp、
  ///          剥掉「歌名 - 歌手」尾巴。
  /// v2 → v3：剥「歌手 - 歌名」前缀与无空格连字符、`[KTV]`/`(Cover)` 版式词、
  ///          繁简表补回 `願 → 愿` 这类首候选是正规简化字的映射。
  /// v3 → v4：按真实曲库 11,425 条重写标题清洗（日期前缀、方括号栏目、
  ///          `歌手-歌名` 与 `歌名 - 歌手` 分流、汉字间隔号、表情符号），
  ///          新增酷狗 / 酷我两个源，并加入刮削资格过滤。
  static const int _missSchema = 4;

  /// 负缓存格式版本字段名。
  static const String _missSchemaKey = 'v';

  static const String _prefsEnabled = 'lyrics_online_enabled';
  static const String _prefsDisabledSources = 'lyrics_online_disabled_sources';

  /// 测试注入点：替换源列表，避免单测依赖真实网络。
  @visibleForTesting
  static List<LyricSource>? sourcesOverride;

  /// 测试注入点：替换负缓存文件路径，避免单测依赖 path_provider 插件。
  @visibleForTesting
  static String? missStorePathOverride;

  /// 测试注入点：替换刮削资格过滤，便于单测直接喂「不可刮」的歌。
  @visibleForTesting
  static LyricSkipReason? Function(SongEntity song)? eligibilityOverride;

  List<LyricSource> get sources => sourcesOverride ?? _sourceOrder;

  final Map<String, Future<LyricFetchResult?>> _inFlight =
      <String, Future<LyricFetchResult?>>{};
  final Map<String, DateTime> _lastCallAt = <String, DateTime>{};
  final Map<String, DateTime> _cooldownUntil = <String, DateTime>{};

  /// 已触发过预热的源，避免每次刷新设置都重来一遍。
  final Set<String> _prewarmed = <String>{};

  bool _enabled = true;
  final Set<String> _disabledSources = <String>{};
  bool _settingsLoaded = false;
  _MissStore? _missStore;

  /// 歌词刮削总开关。
  bool get enabled => _enabled;

  /// 某个源是否启用。
  ///
  /// [_disabledSources] 是用户显式关掉的集合（持久化）；[LyricSource.enabledByDefault]
  /// 只决定**首次安装**时的默认状态，用户改动后以用户选择为准。
  bool isSourceEnabled(String id) => !_disabledSources.contains(id);

  /// 某源当前是否处于限流冷却中。
  bool isCoolingDown(String id) {
    final until = _cooldownUntil[id];
    return until != null && until.isAfter(DateTime.now());
  }

  Future<void> refreshSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_prefsEnabled) ?? true;
    final disabled = prefs.getStringList(_prefsDisabledSources) ?? <String>[];
    _disabledSources
      ..clear()
      ..addAll(disabled);
    _settingsLoaded = true;
    _prewarmSources();
  }

  /// 预热「有一次性下载成本」的源（目前只有 AMLL 的 6 MB 索引）。
  ///
  /// 目前挂在「第一首歌开始加载」这个时点上，与第一轮的其它源并行进行；
  /// 更理想的位置是应用启动，但这里已经足够让用户感觉不到等待。
  void _prewarmSources() {
    for (final source in sources) {
      if (source is AmllTtmlDbSource &&
          isSourceEnabled(source.id) &&
          _prewarmed.add(source.id)) {
        source.prewarm();
      }
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
  }

  Future<void> setSourceEnabled(String id, bool value) async {
    if (value) {
      _disabledSources.remove(id);
    } else {
      _disabledSources.add(id);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsDisabledSources,
      _disabledSources.toList(),
    );
    // 用户刚打开某个源时，顺手把它的一次性下载准备好。
    _prewarmSources();
  }

  /// 清空「试过但没找到」的记忆，让之前失败过的歌重新联网尝试。
  Future<void> clearMissCache() async {
    final store = await _misses();
    await store.clear();
  }

  /// 对单个源做连通性自检。
  ///
  /// 与正常取词的区别（都很重要）：
  /// - **不动任何状态**：不吃也不写失败记忆、不改启用开关；
  /// - **先清掉冷却**：否则「刚被限流 → 立刻点测试」得到的永远只是「还在冷却」，
  ///   用户会以为渠道坏了，其实只是需要等；
  /// - **用探针歌**：见 [LyricSource.probeQuery]，必须是该源一定有的大众歌，
  ///   这样「没查到词」才能真正指向「渠道改版了」而不是「这首歌太偏」。
  Future<LyricProbeResult> probe(LyricSource source) async {
    final stopwatch = Stopwatch()..start();
    final query = source.probeQuery;
    _cooldownUntil.remove(source.id);
    await _throttle(source.id);
    try {
      final result = await source.fetch(query).timeout(source.timeout);
      stopwatch.stop();
      if (result == null) {
        return LyricProbeResult(
          sourceId: source.id,
          status: LyricProbeStatus.noResult,
          message: '能连上，但大众探针歌《${query.title}》没取到词 —— 多半是接口改版了',
          elapsed: stopwatch.elapsed,
        );
      }
      return LyricProbeResult(
        sourceId: source.id,
        status: LyricProbeStatus.ok,
        message: '可用 · ${_formatLabel(result.format)} · ${result.content.length} 字',
        elapsed: stopwatch.elapsed,
        format: result.format,
        chars: result.content.length,
      );
    } on LyricRateLimitedException catch (e) {
      stopwatch.stop();
      _cooldownUntil[source.id] = DateTime.now().add(
        e.retryAfter ?? const Duration(minutes: 10),
      );
      return LyricProbeResult(
        sourceId: source.id,
        status: LyricProbeStatus.rateLimited,
        message: '被限流了 · 需等待 ${_humanDuration(e.retryAfter ?? const Duration(minutes: 10))}',
        elapsed: stopwatch.elapsed,
      );
    } on LyricSourceNotReadyException catch (e) {
      stopwatch.stop();
      return LyricProbeResult(
        sourceId: source.id,
        status: LyricProbeStatus.notReady,
        message: '暂时不可用 · ${e.message}',
        elapsed: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return LyricProbeResult(
        sourceId: source.id,
        status: LyricProbeStatus.failed,
        message: '连不上 · ${_shortError(e)}',
        elapsed: stopwatch.elapsed,
      );
    }
  }

  /// 测试用：清空全部内存态（开关、冷却、单飞、负缓存、设置已加载标记）。
  @visibleForTesting
  void resetForTest() {
    _inFlight.clear();
    _lastCallAt.clear();
    _cooldownUntil.clear();
    _prewarmed.clear();
    _enabled = true;
    _disabledSources.clear();
    _settingsLoaded = false;
    _missStore = null;
  }

  /// 为某首歌取歌词。命中返回结果，未命中返回 `null`（正常情况，不应视为错误）。
  Future<LyricFetchResult?> fetchForSong(SongEntity song) async {
    if (!_settingsLoaded) await refreshSettings();
    if (!_enabled) return null;

    final running = _inFlight[song.guid];
    if (running != null) return running;

    final future = _run(song);
    _inFlight[song.guid] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(song.guid);
    }
  }

  Future<LyricFetchResult?> _run(SongEntity song) async {
    // 先过滤：直播回放 / 播客 / 伴奏 / 清唱这类根本没有歌词可刮，
    // 放它们进网络层只会白烧请求、加速触发限流。
    final skip = eligibilityOverride?.call(song) ??
        LyricEligibility.check(
          title: song.title,
          artist: song.artistDisplay,
          durationMs: song.durationMs,
        );
    if (skip != null) {
      _debug('skip ${song.title}: ${skip.label}');
      return null;
    }

    final query = LyricQuery.fromSong(song);
    if (query.title.trim().isEmpty) return null;

    final active = sources.where((s) => isSourceEnabled(s.id)).toList();
    if (active.isEmpty) return null;

    final store = await _misses();
    final alreadyTried = await store.tried(song.guid);
    final pending =
        active.where((s) => !alreadyTried.contains(s.id)).toList();
    if (pending.isEmpty) {
      _debug('skip ${song.title}: 全部启用源均已试过且无结果');
      return null;
    }

    // 「这次没真正问到」的源单独收集：**暂时不可用**（如索引没下完）和
    // **被限流**都算 —— 它们不代表「这首歌在这个源上没有歌词」，
    // 所以不能写进失败记忆，下次还要再问。
    final skipped = <String>{};

    // 第一轮：只接受带时间轴的歌词（逐字 / 整行）。
    for (final source in pending) {
      final result = await _trySource(
        source,
        query,
        allowPlain: false,
        skipped: skipped,
      );
      if (result != null) {
        await store.clearSong(song.guid);
        _debug('hit ${song.title} <- ${source.id} (${result.format.name})');
        return result;
      }
    }

    // 第二轮：允许纯文本兜底（有总比没有强）。
    for (final source in pending.where((s) => s.supportsPlain)) {
      final result = await _trySource(
        source,
        query,
        allowPlain: true,
        skipped: skipped,
      );
      if (result != null) {
        await store.clearSong(song.guid);
        _debug('hit-plain ${song.title} <- ${source.id}');
        return result;
      }
    }

    final failed = <String>[
      for (final s in pending)
        if (!skipped.contains(s.id)) s.id,
    ];
    if (failed.isEmpty) {
      _debug('miss ${song.title}: 全部源暂时不可用，不写失败记忆');
      return null;
    }
    await store.record(song.guid, failed);
    _debug('miss ${song.title}: 已记录，${_missTtl.inDays} 天内不再重试');
    return null;
  }

  Future<LyricFetchResult?> _trySource(
    LyricSource source,
    LyricQuery query, {
    required bool allowPlain,
    required Set<String> skipped,
  }) async {
    final cooldown = _cooldownUntil[source.id];
    if (cooldown != null && cooldown.isAfter(DateTime.now())) {
      _debug('source ${source.id} 冷却中，跳过');
      return null;
    }
    await _throttle(source.id);
    try {
      return await source
          .fetch(query, allowPlain: allowPlain)
          .timeout(source.timeout);
    } on LyricRateLimitedException catch (e) {
      _cooldownUntil[source.id] = DateTime.now().add(
        e.retryAfter ?? const Duration(minutes: 10),
      );
      // 被限流**不是**「这首歌在这个源上没有歌词」：必须和「暂时不可用」一样
      // 排除在失败记忆之外。否则一次限流冷却期内播过的歌，会被永久性地
      // 记成「这个源已经试过、没有结果」，14 天内不再重试，用户侧就是
      // 「明明以前能搜到，现在怎么都搜不到了」。
      skipped.add(source.id);
      _debug('source ${source.id} 被限流，冷却 ${e.retryAfter ?? '10m'}');
      return null;
    } on LyricSourceNotReadyException catch (e) {
      skipped.add(source.id);
      _debug('source ${source.id} 暂时不可用: ${e.message}');
      return null;
    } catch (e) {
      // 单个源坏掉不能影响其它源，这里静默降级到下一个。
      _debug('source ${source.id} 失败: $e');
      return null;
    }
  }

  Future<void> _throttle(String sourceId) async {
    final last = _lastCallAt[sourceId];
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < _minInterval) {
        await Future<void>.delayed(_minInterval - elapsed);
      }
    }
    _lastCallAt[sourceId] = DateTime.now();
  }

  Future<_MissStore> _misses() async {
    final cached = _missStore;
    if (cached != null) return cached;
    final store = _MissStore(await _missFilePath());
    await store.load();
    _missStore = store;
    return store;
  }

  static Future<String> _missFilePath() async {
    final override = missStorePathOverride;
    if (override != null) return override;
    final dir = await getApplicationSupportDirectory();
    final lyricsDir = Directory(p.join(dir.path, 'lyrics'));
    if (!await lyricsDir.exists()) {
      await lyricsDir.create(recursive: true);
    }
    return p.join(lyricsDir.path, 'online_misses.json');
  }

  static String _formatLabel(LyricFormat format) {
    switch (format) {
      case LyricFormat.wordSynced:
        return '逐字歌词';
      case LyricFormat.lineSynced:
        return '整行歌词';
      case LyricFormat.plain:
        return '纯文本歌词';
    }
  }

  static String _humanDuration(Duration d) {
    if (d.inMinutes >= 1) return '${d.inMinutes} 分钟';
    return '${d.inSeconds} 秒';
  }

  /// 把异常压成一行，别把整段 stack 甩到设置页上。
  static String _shortError(Object e) {
    final s = e.toString().replaceAll('\n', ' ').trim();
    return s.length <= 60 ? s : '${s.substring(0, 60)}…';
  }

  static void _debug(String message) {
    if (kDebugMode) {
      debugPrint('[OnlineLyric] $message');
    }
  }
}

/// 负缓存：记录「这首歌已经把哪些源试过了、都没有」。
///
/// 用 JSON 文件而不是 SharedPreferences，是因为条目会随曲库规模增长，
/// 而 SharedPreferences 在 Android 上会整体加载进内存。
class _MissStore {
  _MissStore(this.path);

  final String path;
  final Map<String, _MissEntry> _entries = <String, _MissEntry>{};

  Future<void> load() async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = json.decode(raw);
      if (decoded is! Map) return;
      final now = DateTime.now();
      decoded.forEach((key, value) {
        if (value is! Map) return;
        // 低版本条目一律丢弃：它们是在旧匹配策略下得出的结论（见 [_missSchema]），
        // 继续沿用会把「其实已经能搜到」的歌一直挡在门外。
        if (value[OnlineLyricSource._missSchemaKey] !=
            OnlineLyricSource._missSchema) {
          return;
        }
        final at = value['at'];
        if (at is! int) return;
        final time = DateTime.fromMillisecondsSinceEpoch(at);
        if (now.difference(time) > OnlineLyricSource._missTtl) return;
        final sources = <String>[];
        if (value['sources'] is List) {
          for (final s in value['sources'] as List) {
            sources.add('$s');
          }
        }
        _entries['$key'] = _MissEntry(time, sources);
      });
    } catch (_) {
      // 缓存损坏就当空的，不影响功能。
    }
  }

  Future<Set<String>> tried(String guid) async {
    final entry = _entries[guid];
    if (entry == null) return <String>{};
    if (DateTime.now().difference(entry.at) > OnlineLyricSource._missTtl) {
      _entries.remove(guid);
      return <String>{};
    }
    return entry.sources.toSet();
  }

  Future<void> record(String guid, List<String> sourceIds) async {
    final previous = _entries[guid];
    final merged = <String>{...sourceIds, ...?previous?.sources};
    _entries[guid] =
        _MissEntry(DateTime.now(), merged.toList(growable: false));
    await _save();
  }

  Future<void> clearSong(String guid) async {
    if (_entries.remove(guid) != null) await _save();
  }

  Future<void> clear() async {
    _entries.clear();
    await _save();
  }

  Future<void> _save() async {
    try {
      final data = <String, Object?>{};
      _entries.forEach((key, entry) {
        data[key] = <String, Object?>{
          OnlineLyricSource._missSchemaKey: OnlineLyricSource._missSchema,
          'at': entry.at.millisecondsSinceEpoch,
          'sources': entry.sources,
        };
      });
      await File(path).writeAsString(json.encode(data), flush: true);
    } catch (_) {
      // 写不进去就算了，只影响下次是否重复联网。
    }
  }
}

class _MissEntry {
  _MissEntry(this.at, this.sources);

  final DateTime at;
  final List<String> sources;
}
