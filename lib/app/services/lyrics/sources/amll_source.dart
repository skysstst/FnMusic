import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'lrc_formats.dart';
import 'lyric_query.dart';
import 'lyric_source.dart';

/// AMLL TTML DataBase（<https://github.com/amll-dev/amll-ttml-db>）歌词源。
///
/// 这是**中文逐字歌词的关键来源**：每首歌按平台音乐 ID 索引，并提供多种格式，
/// 其中 `.eslrc` 恰好就是本项目的解析器原生支持的「行内交错时间戳」增强型 LRC
/// （实测样例：`[00:29.231]故[00:29.692]事[00:30.057]的…`），拿来即可逐字高亮，
/// **无需任何格式转换**。
///
/// 为什么用「本地索引匹配」而不是在线搜索：
/// 该库按平台 ID 而非歌名索引。索引文件 `ncm-lyrics/index.jsonl` 实测约 5.6 MB，
/// 内含 `musicName` / `artists` / `album` / `ncmMusicId` 元数据，下载一次缓存到本地后
/// 就能按「歌名 + 歌手」直接定位 ID，既不依赖第三方搜索接口，也不受其匹配质量影响。
///
/// 冷启动注意（实测踩到过）：
/// 索引首包 6 MB、国内镜像带宽有限时**本机实测要 49 秒**，远超「取歌词」该有的等待。
/// 所以这里做了三件事：① [prewarm] 在后台提前下好；② 单次取歌词最多只等
/// [indexWaitLimit]；③ 等不到就抛 [LyricSourceNotReadyException]（路由层跳过但**不记失败**），
/// 否则一次冷启动就会让本源被拉黑十几天。
class AmllTtmlDbSource extends LyricSource {
  /// 国内镜像优先，最后是 GitHub raw。
  static const List<String> mirrors = <String>[
    'https://amlldb.bikonoo.com',
    'https://amll-ttml-db.gbclstudio.cn',
    'https://amll.mirror.dimeta.top',
    'https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main',
  ];

  /// 索引缓存有效期。
  static const Duration indexTtl = Duration(days: 7);

  /// 索引文件小于该体积视为下载不完整，直接丢弃重下。
  static const int minIndexBytes = 100 * 1024;

  /// 单次取歌词时，最多等索引多久。
  static const Duration indexWaitLimit = Duration(seconds: 8);

  /// 索引下载失败后的静默期：期内不再重复尝试，避免每首歌都白拉几 MB。
  static const Duration indexRetryDelay = Duration(minutes: 10);

  /// 索引只覆盖网易云平台目录（中文曲库占比最高）。
  static const String _platformDir = 'ncm-lyrics';
  static const String _indexFile = 'amll_ncm_index.jsonl';

  /// 测试注入点：替换索引缓存目录，避免单测依赖 path_provider 插件。
  @visibleForTesting
  static String? cacheDirOverride;

  @override
  String get id => 'amll';

  @override
  String get displayName => 'AMLL TTML DB';

  @override
  String get description => '中文逐字歌词库（首次使用需下载约 6 MB 索引）';

  @override
  bool get enabledByDefault => true;

  /// 连通性自检的探针歌。
  ///
  /// AMLL 索引只覆盖网易云平台目录，中文大众歌命中率最高，《晴天》是稳中的一首。
  /// 注意本源**首次使用要先下 6 MB 索引**，所以第一次测试耗时会明显偏长
  /// （或在索引没下完时直接报「暂时不可用」），这属于预期行为。
  @override
  LyricQuery get probeQuery => const LyricQuery(
        title: '晴天',
        artist: '周杰伦',
        durationMs: 269000,
      );

  @override
  Duration get timeout => const Duration(seconds: 25);

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60),
      headers: <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126 Safari/537.36',
      },
      validateStatus: (int? code) => code != null && code < 500,
    ),
  );

  _AmllIndex? _index;
  Future<_AmllIndex?>? _indexFuture;
  DateTime? _indexFailedAt;
  String? _workingMirror;

  /// 在后台提前把索引下好。应用启动时调用一次即可（失败无所谓）。
  void prewarm() {
    unawaited(_loadIndexOnce());
  }

  @override
  Future<LyricFetchResult?> fetch(
    LyricQuery query, {
    bool allowPlain = false,
  }) async {
    final index = await _awaitIndex();

    final entry = index.bestMatch(query);
    if (entry == null) return null;

    final content = await _downloadLyric(entry.id, 'eslrc');
    if (content == null) return null;
    final text = LrcFormats.sanitize(content);
    if (!LrcFormats.isWordSynced(text)) return null;

    // 索引里没有时长字段，用「歌词最后一个时间戳」做一次粗校验，
    // 避免把同名不同版本（如 3 分钟 vs 6 分钟）的歌词贴上。
    if (!_durationPlausible(text, query.durationMs)) return null;

    return LyricFetchResult(
      content: text,
      sourceId: id,
      format: LyricFormat.wordSynced,
      matchedTitle: entry.title,
      matchedArtist: entry.artists,
      matchedDurationMs: null,
    );
  }

  /// 取索引；拿不到就抛 [LyricSourceNotReadyException]，**不返回 null**——
  /// null 会被路由层当成「这首歌没有歌词」并记进失败记忆，那是错的。
  Future<_AmllIndex> _awaitIndex() async {
    final cached = _index;
    if (cached != null) return cached;

    final failedAt = _indexFailedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < indexRetryDelay) {
      throw LyricSourceNotReadyException(id, '索引下载失败，静默期内不重试');
    }

    _AmllIndex? loaded;
    try {
      loaded = await _loadIndexOnce().timeout(indexWaitLimit);
    } on TimeoutException {
      // 索引还在下（往往是首包），这次先跳过，下次就快了。
      throw LyricSourceNotReadyException(id, '索引尚未下载完成');
    }
    if (loaded == null) {
      _indexFailedAt = DateTime.now();
      throw LyricSourceNotReadyException(id, '索引下载失败');
    }
    _indexFailedAt = null;
    return loaded;
  }

  /// 索引加载去重：连续两首歌并发进来时共享同一次下载，避免重复拉 6 MB。
  Future<_AmllIndex?> _loadIndexOnce() {
    final running = _indexFuture;
    if (running != null) return running;
    final future = _loadIndex();
    _indexFuture = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_indexFuture, future)) _indexFuture = null;
      }),
    );
    return future;
  }

  /// 加载索引。**本方法不抛异常**，失败一律返回 null，调用方负责判断。
  Future<_AmllIndex?> _loadIndex() async {
    try {
      final file = await _indexPath();
      if (!await _indexIsFresh(file)) {
        await _downloadIndex(file);
      }
      // 下载失败时，只要旧缓存还在且完整，就继续用旧的（总比没有强）。
      if (!await file.exists() || await file.length() < minIndexBytes) {
        return null;
      }
      final lines = await file.readAsLines();
      _index = _AmllIndex.parse(lines);
      return _index;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _downloadLyric(String id, String suffix) async {
    for (final mirror in _mirrorOrder()) {
      try {
        final res = await _dio.get<String>(
          '$mirror/$_platformDir/$id.$suffix',
          options: Options(responseType: ResponseType.plain),
        );
        if (res.statusCode == 200 && (res.data ?? '').trim().isNotEmpty) {
          _workingMirror = mirror;
          return res.data;
        }
      } catch (_) {
        // 换下一个镜像。
      }
    }
    return null;
  }

  List<String> _mirrorOrder() {
    final working = _workingMirror;
    if (working == null) return mirrors;
    return <String>[working, ...mirrors.where((m) => m != working)];
  }

  Future<File> _indexPath() async {
    final override = cacheDirOverride;
    if (override != null) {
      final dir = Directory(override);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return File(p.join(override, _indexFile));
    }
    final dir = await getApplicationSupportDirectory();
    final lyricsDir = Directory(p.join(dir.path, 'lyrics'));
    if (!await lyricsDir.exists()) {
      await lyricsDir.create(recursive: true);
    }
    return File(p.join(lyricsDir.path, _indexFile));
  }

  Future<bool> _indexIsFresh(File file) async {
    try {
      if (!await file.exists()) return false;
      if (await file.length() < minIndexBytes) return false;
      final age = DateTime.now().difference((await file.stat()).modified);
      return age < indexTtl;
    } catch (_) {
      return false;
    }
  }

  /// 下载索引。**先写临时文件再原子改名**，避免中途失败留下个半截索引
  /// ——那会让后续每一首歌都解析出一个残缺的索引。
  Future<void> _downloadIndex(File file) async {
    final tempPath = '${file.path}.tmp';
    for (final mirror in _mirrorOrder()) {
      try {
        final res = await _dio.download(
          '$mirror/$_platformDir/index.jsonl',
          tempPath,
        );
        final temp = File(tempPath);
        if (res.statusCode == 200 && await temp.length() >= minIndexBytes) {
          await temp.rename(file.path);
          _workingMirror = mirror;
          return;
        }
      } catch (_) {
        // 换下一个镜像。
      }
    }
    // 全部镜像失败：清掉临时文件，保留旧缓存。
    try {
      final temp = File(tempPath);
      if (await temp.exists()) await temp.delete();
    } catch (_) {}
  }

  static bool _durationPlausible(String lrc, int? durationMs) {
    if (durationMs == null || durationMs <= 0) return true;
    final reg = RegExp(r'\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]');
    var maxMs = 0;
    for (final m in reg.allMatches(lrc)) {
      final mm = int.tryParse(m.group(1) ?? '0') ?? 0;
      final ss = int.tryParse(m.group(2) ?? '0') ?? 0;
      final frac = m.group(3);
      final ms = frac == null
          ? 0
          : int.tryParse(frac.padRight(3, '0').substring(0, 3)) ?? 0;
      final t = mm * 60000 + ss * 1000 + ms;
      if (t > maxMs) maxMs = t;
    }
    // 歌词不应在歌曲结束前一分钟以上就没了，也不该超出太多。
    return maxMs <= durationMs + 60000 && maxMs >= durationMs - 120000;
  }
}

/// 一条 AMLL 索引记录（只保留匹配需要的字段，避免把整个 JSON 留在内存里）。
class _AmllEntry {
  const _AmllEntry({
    required this.id,
    required this.title,
    required this.artists,
  });

  final String id;
  final String title;
  final String artists;

  bool get hasArtist => artists.trim().isNotEmpty;
}

class _AmllIndex {
  _AmllIndex(this._byTitle);

  final Map<String, List<_AmllEntry>> _byTitle;

  static _AmllIndex parse(List<String> lines) {
    final byTitle = <String, List<_AmllEntry>>{};
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      try {
        final map = json.decode(t);
        if (map is! Map) continue;
        final id = '${map['id'] ?? ''}';
        if (id.isEmpty) continue;
        final meta = <String, List<String>>{};
        final rawMeta = map['metadata'];
        if (rawMeta is List) {
          for (final pair in rawMeta) {
            if (pair is! List || pair.isEmpty) continue;
            final key = '${pair[0]}';
            final values = <String>[];
            if (pair.length > 1 && pair[1] is List) {
              for (final v in pair[1] as List) {
                values.add('$v');
              }
            }
            meta[key] = values;
          }
        }
        final names = meta['musicName'];
        if (names == null || names.isEmpty) continue;
        final artists = (meta['artists'] ?? const <String>[]).join('/');
        for (final name in names) {
          final key = LyricTextNorm.normalize(name);
          if (key.isEmpty) continue;
          byTitle
              .putIfAbsent(key, () => <_AmllEntry>[])
              .add(_AmllEntry(id: id, title: name, artists: artists));
        }
      } catch (_) {
        // 单行损坏不影响整体索引。
        continue;
      }
    }
    return _AmllIndex(byTitle);
  }

  _AmllEntry? bestMatch(LyricQuery query) {
    final exact = _byTitle[query.titleKey];
    if (exact != null && exact.isNotEmpty) {
      final hit = _pickByArtist(exact, query);
      if (hit != null) return hit;
    }
    // 歌名不完全相同（如带 (Live) 后缀）时，用包含关系兜一次，
    // 但要求歌手必须对上，避免误配。长度门槛与 sameTitle 共用同一判据。
    if (query.titleKey.length <
        LyricTextNorm.containMinLength(query.titleKey)) {
      return null;
    }
    for (final entry in _byTitle.entries) {
      if (!entry.key.contains(query.titleKey) &&
          !query.titleKey.contains(entry.key)) {
        continue;
      }
      final hit = _pickByArtist(entry.value, query);
      if (hit != null) return hit;
    }
    return null;
  }

  _AmllEntry? _pickByArtist(List<_AmllEntry> candidates, LyricQuery query) {
    if (query.artistKey.isEmpty) {
      return candidates.length == 1 ? candidates.first : null;
    }
    for (final c in candidates) {
      final artists = c.artists.split('/');
      for (final a in artists) {
        if (LyricTextNorm.artistMatches(query.artist, a)) return c;
      }
    }
    // 索引里没写歌手时允许唯一候选通过。
    final noArtist = candidates.where((c) => !c.hasArtist).toList();
    return noArtist.length == 1 && candidates.length == 1 ? noArtist.first : null;
  }
}
