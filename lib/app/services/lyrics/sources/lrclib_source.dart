import 'package:dio/dio.dart';

import 'lrc_formats.dart';
import 'lyric_query.dart';
import 'lyric_source.dart';

/// LRCLIB（<https://lrclib.net>）—— 免费、无需 API key 的公共歌词库。
///
/// 实测要点（不要凭印象改）：
/// - **不要走代理**：本机实测走 Clash 时直接返回 429，直连反而 200。
/// - `duration` 是服务端**强制**校验项：不符（±2 秒）直接 404。所以带 `duration`
///   的 `/api/get` 命中率最稳；带不上时长时才退回 `/api/search` 自行筛选。
/// - 必须带 `User-Agent` 标识客户端；被限流时返回 429 + `Retry-After`。
/// - 部分记录是繁体（同一首歌可能有简繁两版），属于数据源特性，不做改写。
class LrclibSource extends LyricSource {
  static const String baseUrl = 'https://lrclib.net';
  static const String userAgent =
      'FnMusicLyricsFetcher/1.0 (https://github.com/skysstst/FnMusic)';

  /// 时长筛选容差：与 LRCLIB 服务端保持同一口径（±2 秒）。
  static const int durationToleranceMs = 2000;

  @override
  String get id => 'lrclib';

  @override
  String get displayName => 'LRCLIB';

  @override
  String get description => '免费公共歌词库，欧美曲库最全，部分含逐字';

  @override
  bool get enabledByDefault => true;

  @override
  bool get supportsPlain => true;

  /// 连通性自检的探针歌。
  ///
  /// 这里**不能用中文歌**：LRCLIB 是欧美曲库为主的公共库，中文歌覆盖率很低，
  /// 拿《晴天》去测会稳定「没结果」，把「渠道正常但没这首歌」误报成「渠道坏了」。
  /// `Hey Jude` 是实测 `/api/get` 必中、且带 `syncedLyrics` 的那一类。
  @override
  LyricQuery get probeQuery => const LyricQuery(
        title: 'Hey Jude',
        artist: 'The Beatles',
        durationMs: 431000,
      );

  late final Dio _dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      headers: <String, String>{
        'User-Agent': userAgent,
        'Lrclib-Client': userAgent,
        'Accept': 'application/json',
      },
      // 把 4xx / 5xx 都当作正常响应处理，便于按状态码分流：
      // 404 是「没这首歌」，429 与 5xx 都是「该退避了」。
      validateStatus: (int? code) => code != null && code < 600,
    ),
  );

  @override
  Future<LyricFetchResult?> fetch(
    LyricQuery query, {
    bool allowPlain = false,
  }) async {
    final exact = await _fetchExact(query, allowPlain: allowPlain);
    if (exact != null) return exact;
    // /api/get 没命中（或无时长可传）→ 用搜索接口自行挑最合适的一条。
    final withArtist =
        await _searchAndPick(query, allowPlain: allowPlain, useArtist: true);
    if (withArtist != null) return withArtist;
    if (query.artist.isEmpty) return null;
    // 补一轮「只按歌名搜」：翻唱库里歌手永远对不上，带歌手搜会被服务端直接滤空。
    return _searchAndPick(query, allowPlain: allowPlain, useArtist: false);
  }

  Future<LyricFetchResult?> _fetchExact(
    LyricQuery query, {
    required bool allowPlain,
  }) async {
    final params = <String, Object?>{
      'track_name': query.title,
      'artist_name': query.artist,
      if (query.album != null && query.album!.trim().isNotEmpty)
        'album_name': query.album,
      if (query.durationMs != null)
        'duration': (query.durationMs! / 1000).round(),
    };
    final res = await _dio.get<Object?>('/api/get', queryParameters: params);
    _throwIfRateLimited(res);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw LyricSourceException(id, 'HTTP ${res.statusCode}');
    }
    final map = _asMap(res.data);
    if (map == null) return null;
    return _buildResult(map, allowPlain: allowPlain);
  }

  /// 搜索并挑一条最合适的。
  ///
  /// [useArtist] 为 false 时**不把歌手发给服务端**：LRCLIB 的 `/api/search`
  /// 会按 `artist_name` 在**服务端**过滤，而翻唱库里歌曲记的是翻唱者、LRCLIB
  /// 只有原唱，带着歌手搜必然空手而归。此时改为只按歌名搜，回来再靠本地打分挑版本。
  Future<LyricFetchResult?> _searchAndPick(
    LyricQuery query, {
    required bool allowPlain,
    required bool useArtist,
  }) async {
    final res = await _dio.get<Object?>(
      '/api/search',
      queryParameters: <String, Object?>{
        'track_name': query.title,
        if (useArtist && query.artist.isNotEmpty) 'artist_name': query.artist,
      },
    );
    _throwIfRateLimited(res);
    if (res.statusCode != 200) return null;
    final list = res.data;
    if (list is! List) return null;

    Map<String, Object?>? best;
    var bestScore = 0;
    for (final item in list) {
      final map = _asMap(item);
      if (map == null) continue;
      if (map['instrumental'] == true) continue;
      final durationMs = LyricTextNorm.secondsToMs(map['duration'] as num?);
      // 与其它源共用同一套判据：歌手是加分项，跨歌手时要求歌名完全一致 + 时长贴合。
      var score = LyricTextNorm.scoreCandidate(
        queryTitle: query.title,
        queryArtist: query.artist,
        queryDurationMs: query.durationMs,
        candidateTitle: '${map['trackName'] ?? map['name'] ?? ''}',
        candidateArtists: <String>['${map['artistName'] ?? ''}'],
        candidateDurationMs: durationMs,
        durationToleranceMs: durationToleranceMs,
      );
      if (score <= 0) continue;
      // LRCLIB 特有的加分：带同步歌词、带逐字歌词的优先。
      if (map['syncedLyrics'] is String) score += 3;
      if (map['hasWordSync'] == true) score += 2;
      if (score > bestScore) {
        bestScore = score;
        best = map;
      }
    }
    if (best == null) return null;
    return _buildResult(best, allowPlain: allowPlain);
  }

  LyricFetchResult? _buildResult(
    Map<String, Object?> map, {
    required bool allowPlain,
  }) {
    if (map['instrumental'] == true) return null;
    final synced = _nonEmpty(map['syncedLyrics']);
    final title = '${map['trackName'] ?? map['name'] ?? ''}';
    final artist = '${map['artistName'] ?? ''}';
    final durationMs = LyricTextNorm.secondsToMs(map['duration'] as num?);

    if (synced != null) {
      final text = LrcFormats.sanitize(synced);
      if (LrcFormats.hasSyncedLines(text)) {
        return LyricFetchResult(
          content: text,
          sourceId: id,
          format: LrcFormats.isWordSynced(text)
              ? LyricFormat.wordSynced
              : LyricFormat.lineSynced,
          matchedTitle: title,
          matchedArtist: artist,
          matchedDurationMs: durationMs,
        );
      }
    }

    if (!allowPlain) return null;
    final plain = _nonEmpty(map['plainLyrics']);
    if (plain == null) return null;
    return LyricFetchResult(
      content: plain,
      sourceId: id,
      format: LyricFormat.plain,
      matchedTitle: title,
      matchedArtist: artist,
      matchedDurationMs: durationMs,
    );
  }

  /// 判定「需要退避」并把响应转成限流异常。
  ///
  /// 429 是显式限流（带 `Retry-After`）；**5xx 也算**——实测 LRCLIB 过载时
  /// 会在连续请求下返回 503，若按普通错误处理，路由层只会静默降级到下一个源、
  /// 不给冷却，于是下一首歌又会立刻捶它。统一退避才是对的。
  void _throwIfRateLimited(Response<Object?> res) {
    final code = res.statusCode;
    if (code == null) return;
    if (code != 429 && code < 500) return;
    final header = res.headers.value('retry-after');
    final seconds = header == null ? null : int.tryParse(header.trim());
    throw LyricRateLimitedException(
      id,
      retryAfter: seconds == null ? null : Duration(seconds: seconds),
    );
  }

  static String? _nonEmpty(Object? value) {
    if (value is! String) return null;
    final t = value.trim();
    return t.isEmpty ? null : t;
  }

  static Map<String, Object?>? _asMap(Object? data) {
    if (data is Map) return data.cast<String, Object?>();
    return null;
  }
}
