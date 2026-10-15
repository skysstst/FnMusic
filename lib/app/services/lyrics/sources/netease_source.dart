import 'package:dio/dio.dart';

import 'lrc_formats.dart';
import 'lyric_query.dart';
import 'lyric_source.dart';

/// 网易云音乐歌词源（非官方公开接口）。
///
/// 实测结论：
/// - 搜索 `music.163.com/api/search/get/web`、歌词 `music.163.com/api/song/lyric`
///   **直连可用**，需要带 `Referer: https://music.163.com/`。
/// - **拿不到逐字**：返回体里没有 `yrc` 字段（逐字要走加密的 eapi 通道，
///   不做实现）。本源定位是「中文整行歌词 + 翻译」，逐字交给 AMLL 源。
/// - 搜索接口按「歌名+歌手」混搜时会返回一堆翻唱（实测「晴天 周杰伦」前三条
///   全不是原唱），所以这里先只用歌名搜，再在本地按歌手 + 时长筛。
class NeteaseSource extends LyricSource {
  static const String _searchUrl =
      'https://music.163.com/api/search/get/web';
  static const String _lyricUrl = 'https://music.163.com/api/song/lyric';

  /// 候选筛选容差，比 LRCLIB 放宽一点：网易云返回的时长偶尔与曲库有偏差。
  static const int durationToleranceMs = 4000;

  @override
  String get id => 'netease';

  @override
  String get displayName => '网易云音乐';

  @override
  String get description => '中文整行歌词 + 翻译（非官方接口，可能变动）';

  @override
  bool get enabledByDefault => true;

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      headers: <String, String>{
        'Referer': 'https://music.163.com/',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126 Safari/537.36',
        'Accept': 'application/json, text/plain, */*',
      },
      validateStatus: (int? code) => code != null && code < 500,
    ),
  );

  @override
  Future<LyricFetchResult?> fetch(
    LyricQuery query, {
    bool allowPlain = false,
  }) async {
    // 第一轮：只用歌名搜（命中率最高），本地筛歌手与时长。
    var song = await _searchAndPick(query, query.title);
    // 第二轮：歌名太泛（如 "Hello"）导致筛不出人时，再带上歌手搜一次。
    if (song == null && query.artist.isNotEmpty) {
      song = await _searchAndPick(query, '${query.title} ${query.artist}');
    }
    if (song == null) return null;

    final songId = song['id'];
    if (songId == null) return null;
    return _fetchLyric(query, songId, song);
  }

  Future<Map<String, Object?>?> _searchAndPick(
    LyricQuery query,
    String keyword,
  ) async {
    final res = await _dio.get<Object?>(
      _searchUrl,
      queryParameters: <String, Object?>{
        's': keyword,
        'type': 1,
        'limit': 20,
        'offset': 0,
      },
    );
    if (res.statusCode != 200) return null;
    _throwIfRateLimited(res.data);
    final root = _asMap(res.data);
    final result = _asMap(root?['result']);
    final songs = result?['songs'];
    if (songs is! List) return null;

    Map<String, Object?>? best;
    var bestScore = 0;
    for (final item in songs) {
      final song = _asMap(item);
      if (song == null) continue;
      // 筛选与打分统一走 LyricTextNorm.scoreCandidate：歌手是加分项不是门槛，
      // 跨歌手（翻唱库常态）时靠「歌名完全一致 + 时长贴合」放行。
      final score = LyricTextNorm.scoreCandidate(
        queryTitle: query.title,
        queryArtist: query.artist,
        queryDurationMs: query.durationMs,
        candidateTitle: '${song['name'] ?? ''}',
        candidateArtists: _artistNames(song['artists']),
        candidateDurationMs:
            song['duration'] is num ? (song['duration'] as num).round() : null,
        durationToleranceMs: durationToleranceMs,
      );
      if (score > bestScore) {
        bestScore = score;
        best = song;
      }
    }
    return best;
  }

  Future<LyricFetchResult?> _fetchLyric(
    LyricQuery query,
    Object songId,
    Map<String, Object?> song,
  ) async {
    final res = await _dio.get<Object?>(
      _lyricUrl,
      queryParameters: <String, Object?>{
        'id': songId,
        'lv': -1,
        'kv': -1,
        'tv': -1,
        'rv': -1,
      },
    );
    if (res.statusCode != 200) return null;
    _throwIfRateLimited(res.data);
    final root = _asMap(res.data);
    if (root == null) return null;
    final main = _lyricOf(root['lrc']);
    if (main == null) return null;
    final trans = _lyricOf(root['tlyric']);
    // 富文本行（`{"t":0,...}`）交给 sanitize 统一丢掉。
    final merged = LrcFormats.mergeTranslation(main, trans);
    final text = LrcFormats.sanitize(merged);
    if (!LrcFormats.hasSyncedLines(text)) return null;

    final artists = _artistNames(song['artists']);
    return LyricFetchResult(
      content: text,
      sourceId: id,
      format: LrcFormats.isWordSynced(text)
          ? LyricFormat.wordSynced
          : LyricFormat.lineSynced,
      matchedTitle: '${song['name'] ?? query.title}',
      matchedArtist: artists.isEmpty ? null : artists.join('/'),
      matchedDurationMs:
          song['duration'] is num ? (song['duration'] as num).round() : null,
    );
  }

  /// 网易云把**限流包在 HTTP 200 里**：`{"msg":"操作频繁，请稍候再试","code":405}`。
  ///
  /// 不识别它就会被当成「这首歌没有结果」静默吞掉 —— 路由层既不会给这个源降温，
  /// 还会在之后**每一首歌**上继续白问一次。实测连续跑几十首之后网易会稳定返回
  /// 405，于是净命中全压在单一源（QQ）身上，用户侧表现为「突然怎么都搜不到词」。
  /// 所以这里必须抛 [LyricRateLimitedException]，让路由层按冷却跳过。
  ///
  /// 注意判的是**响应体里的业务码**，不是 HTTP 状态码（后者仍是 200）。
  static void _throwIfRateLimited(Object? data) {
    final code = _asMap(data)?['code'];
    if (code is! num || code.toInt() != 405) return;
    throw LyricRateLimitedException(
      'netease',
      retryAfter: const Duration(minutes: 5),
    );
  }

  static List<String> _artistNames(Object? value) {
    if (value is! List) return const <String>[];
    final out = <String>[];
    for (final item in value) {
      final map = _asMap(item);
      final name = map == null ? null : '${map['name'] ?? ''}'.trim();
      if (name != null && name.isNotEmpty) out.add(name);
    }
    return out;
  }

  static String? _lyricOf(Object? value) {
    final map = _asMap(value);
    final lyric = map == null ? null : map['lyric'];
    if (lyric is! String) return null;
    final t = lyric.trim();
    return t.isEmpty ? null : t;
  }

  static Map<String, Object?>? _asMap(Object? data) {
    if (data is Map) return data.cast<String, Object?>();
    return null;
  }
}
