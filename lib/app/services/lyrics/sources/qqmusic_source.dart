import 'dart:convert';

import 'package:dio/dio.dart';

import 'lrc_formats.dart';
import 'lyric_query.dart';
import 'lyric_source.dart';

/// QQ 音乐歌词源（非官方公开接口）。
///
/// 实测结论：
/// - 搜索 `c.y.qq.com/soso/fcgi-bin/client_search_cp`、歌词
///   `c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg` 直连可用，
///   带 `Referer: https://y.qq.com/` 即可，返回的是**简体** LRC（比 LRCLIB 更贴中文曲库）。
/// - `nobase64=1` 可以直接拿到明文歌词，省掉一次 base64 解码。
/// - **两个接口都不返回 `application/json`**（搜索是 `application/x-javascript`，
///   歌词是 `text/html`），Dio 会原样给出 String 而不解析，所以这里统一走
///   [_decode] 手动解码，不依赖 Content-Type 嗅探。
/// - 逐字（QRC）需要走 `musicu.fcg` 的加密通道，本实现不做，
///   定位与网易云源一致：中文整行 + 翻译。
class QqMusicSource extends LyricSource {
  /// 搜索接口。
  ///
  /// **别改回 `client_search_cp`**：该端点已失效，实测直连与走代理都稳定返回
  /// HTTP 500（空响应体），会导致整个 QQ 源静默降级。`search_for_qq_cp` 的
  /// 返回结构与它完全一致（`data.song.list`，含 `songmid` / `songname` /
  /// `singer` / `interval`），换过来即可。
  static const String _searchUrl =
      'https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp';
  static const String _lyricUrl =
      'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg';

  static const int durationToleranceMs = 4000;

  @override
  String get id => 'qqmusic';

  @override
  String get displayName => 'QQ 音乐';

  @override
  String get description => '中文整行歌词 + 翻译（非官方接口，可能变动）';

  @override
  bool get enabledByDefault => true;

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      headers: <String, String>{
        'Referer': 'https://y.qq.com/portal/player.html',
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
    var song = await _searchAndPick(query, query.title);
    if (song == null && query.artist.isNotEmpty) {
      song = await _searchAndPick(query, '${query.title} ${query.artist}');
    }
    if (song == null) return null;
    final mid = '${song['songmid'] ?? ''}';
    if (mid.isEmpty) return null;
    return _fetchLyric(query, mid, song);
  }

  Future<Map<String, Object?>?> _searchAndPick(
    LyricQuery query,
    String keyword,
  ) async {
    final res = await _dio.get<Object?>(
      _searchUrl,
      queryParameters: <String, Object?>{
        'p': 1,
        'n': 20,
        'w': keyword,
        'format': 'json',
      },
    );
    if (res.statusCode != 200) return null;
    final data = _asMap(_asMap(_decode(res.data))?['data']);
    final songNode = _asMap(data?['song']);
    final list = songNode?['list'];
    if (list is! List) return null;

    Map<String, Object?>? best;
    var bestScore = 0;
    for (final item in list) {
      final song = _asMap(item);
      if (song == null) continue;
      // 与网易云一致：走 LyricTextNorm.scoreCandidate，歌手只是加分项。
      final score = LyricTextNorm.scoreCandidate(
        queryTitle: query.title,
        queryArtist: query.artist,
        queryDurationMs: query.durationMs,
        candidateTitle: '${song['songname'] ?? ''}',
        candidateArtists: _artistNames(song['singer']),
        candidateDurationMs: _durationMs(song),
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
    String songMid,
    Map<String, Object?> song,
  ) async {
    final res = await _dio.get<Object?>(
      _lyricUrl,
      queryParameters: <String, Object?>{
        'songmid': songMid,
        'format': 'json',
        'nobase64': 1,
      },
    );
    if (res.statusCode != 200) return null;
    final root = _asMap(_decode(res.data));
    if (root == null) return null;
    final main = _nonEmpty(root['lyric']);
    if (main == null) return null;
    final merged = LrcFormats.mergeTranslation(main, _nonEmpty(root['trans']));
    final text = LrcFormats.sanitize(merged);
    if (!LrcFormats.hasSyncedLines(text)) return null;

    final artists = _artistNames(song['singer']);
    return LyricFetchResult(
      content: text,
      sourceId: id,
      format: LrcFormats.isWordSynced(text)
          ? LyricFormat.wordSynced
          : LyricFormat.lineSynced,
      matchedTitle: '${song['songname'] ?? query.title}',
      matchedArtist: artists.isEmpty ? null : artists.join('/'),
      matchedDurationMs: _durationMs(song),
    );
  }

  /// QQ 的时长字段 `interval` 单位是**秒**，统一换成毫秒。
  ///
  /// 注意括号：`as` 的优先级低于 `*`，写成 `x as num * 1000` 会被解析成
  /// `x as (num * 1000)` 而编译失败。
  static int? _durationMs(Map<String, Object?> song) {
    final value = song['interval'];
    if (value is! num) return null;
    return (value * 1000).round();
  }

  /// 把响应体统一转成可用的 JSON 结构。
  ///
  /// Dio 只在 Content-Type 是 JSON 时才自动解码；QQ 两个接口都不返回
  /// `application/json`，此时 `res.data` 是原始 String，需要自己解一次。
  static Object? _decode(Object? data) {
    if (data is String) {
      final text = data.trim();
      if (text.isEmpty) return null;
      try {
        return jsonDecode(text);
      } catch (_) {
        return null;
      }
    }
    return data;
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
