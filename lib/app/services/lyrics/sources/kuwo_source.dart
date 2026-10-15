import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'lrc_formats.dart';
import 'lyric_query.dart';
import 'lyric_source.dart';

/// 酷我音乐歌词源。
///
/// 实测要点：
/// - 搜索走 `search.kuwo.cn/r.s`，它返回的**不是合法 JSON**：键用单引号、
///   正文里带 `&nbsp;` 之类的 HTML 实体（`'SONGNAME':'晴天&nbsp;(KTV版伴奏)'`）。
///   用 JSON 解析器会直接炸，所以这里按字段正则取值，不试图「修好」成 JSON。
/// - 歌词走 `m.kuwo.cn/newh5/singles/songinfoandlrc`，返回
///   `{"data":{"lrclist":[{"time":"29.26","lineLyric":"故事的小黄花"}]}}`，
///   需要自己拼成 LRC。
/// - **必须遍历候选**：实测 `水星记` 前 5 条里只有第 2 条（`水星记（原版）`）
///   有词，其余是 Live 片段 / 钢琴版 / 无词条目。只取第一条会漏掉大半。
/// - 搜索接口返回 `text/plain`，不给 `application/json`，别依赖 Content-Type 嗅探。
class KuwoSource extends LyricSource {
  static const String _searchUrl = 'https://search.kuwo.cn/r.s';

  /// 歌词接口。
  static const String _lyricUrl =
      'https://m.kuwo.cn/newh5/singles/songinfoandlrc';

  static const int durationToleranceMs = 4000;

  /// 最多回查几条候选的歌词。太少会漏（第一条常是伴奏），太多会白烧请求。
  static const int maxLyricLookups = 4;

  @override
  String get id => 'kuwo';

  @override
  String get displayName => '酷我音乐';

  @override
  String get description => '中文整行歌词（非官方接口，返回非标准 JSON）';

  @override
  bool get enabledByDefault => true;

  @override
  LyricQuery get probeQuery => const LyricQuery(
        title: '晴天',
        artist: '周杰伦',
        durationMs: 269000,
      );

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      headers: <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126 Safari/537.36',
        'Accept': 'application/json, text/plain, */*',
        'Referer': 'https://www.kuwo.cn/',
      },
      validateStatus: (int? code) => code != null && code < 600,
    ),
  );

  @override
  Future<LyricFetchResult?> fetch(
    LyricQuery query, {
    bool allowPlain = false,
  }) async {
    var songs = await _searchSongs(query, query.title);
    if (songs.isEmpty && query.artist.isNotEmpty) {
      songs = await _searchSongs(query, '${query.title} ${query.artist}');
    }
    if (songs.isEmpty) return null;

    // 按打分降序，逐条试歌词；第一条常常是伴奏 / Live 片段，没有词。
    songs.sort((a, b) => b.score.compareTo(a.score));
    final limit = songs.length < maxLyricLookups ? songs.length : maxLyricLookups;
    for (var i = 0; i < limit; i++) {
      final song = songs[i];
      final result = await _fetchLyric(query, song);
      if (result != null) return result;
    }
    return null;
  }

  Future<List<_KuwoSong>> _searchSongs(
    LyricQuery query,
    String keyword,
  ) async {
    final res = await _dio.get<Object?>(
      _searchUrl,
      queryParameters: <String, Object?>{
        'all': keyword,
        'ft': 'music',
        'itemset': 'web_2013',
        'client': 'kt',
        'pn': 0,
        'rn': 20,
        'rformat': 'json',
        'encoding': 'utf8',
      },
    );
    _throwIfRateLimited(res);
    if (res.statusCode != 200) return const <_KuwoSong>[];

    final text = '${res.data}';
    final ids = _pickAll(text, r"'MUSICRID':'(?:MUSIC_)?(\d+)'");
    if (ids.isEmpty) return const <_KuwoSong>[];
    final names = _pickAll(text, r"'SONGNAME':'([^']*)'");
    final artists = _pickAll(text, r"'ARTIST':'([^']*)'");
    final durations = _pickAll(text, r"'DURATION':'(\d+)'");

    final out = <_KuwoSong>[];
    for (var i = 0; i < ids.length; i++) {
      final title = _unescape(i < names.length ? names[i] : '');
      final artist = _unescape(i < artists.length ? artists[i] : '');
      final seconds =
          i < durations.length ? int.tryParse(durations[i]) : null;
      final score = LyricTextNorm.scoreCandidate(
        queryTitle: query.title,
        queryArtist: query.artist,
        queryDurationMs: query.durationMs,
        candidateTitle: title,
        candidateArtists: <String>[artist],
        candidateDurationMs: seconds == null ? null : seconds * 1000,
        durationToleranceMs: durationToleranceMs,
      );
      if (score <= 0) continue;
      out.add(_KuwoSong(
        id: ids[i],
        title: title,
        artist: artist,
        durationMs: seconds == null ? null : seconds * 1000,
        score: score,
      ));
    }
    return out;
  }

  Future<LyricFetchResult?> _fetchLyric(
    LyricQuery query,
    _KuwoSong song,
  ) async {
    final res = await _dio.get<Object?>(
      _lyricUrl,
      queryParameters: <String, Object?>{
        'musicId': song.id,
        'httpsStatus': 1,
      },
      options: Options(
        headers: <String, String>{
          // 少了 Referer 会被判成「音乐查询失败」。
          'Referer': 'https://m.kuwo.cn/yinyue/${song.id}',
        },
      ),
    );
    _throwIfRateLimited(res);
    if (res.statusCode != 200) return null;

    final root = _asMap(_decode(res.data));
    final data = _asMap(root?['data']);
    final rows = data?['lrclist'];
    if (rows is! List || rows.isEmpty) return null;

    final lrc = _buildLrc(rows);
    final text = LrcFormats.sanitize(lrc);
    if (!LrcFormats.hasSyncedLines(text)) return null;

    return LyricFetchResult(
      content: text,
      sourceId: id,
      format: LrcFormats.isWordSynced(text)
          ? LyricFormat.wordSynced
          : LyricFormat.lineSynced,
      matchedTitle: song.title.isEmpty ? query.title : song.title,
      matchedArtist: song.artist.isEmpty ? null : song.artist,
      matchedDurationMs: song.durationMs,
    );
  }

  /// `lrclist` → LRC 文本。酷我给的是**秒**（`29.26`），要转成 `[mm:ss.cc]`。
  static String _buildLrc(List<Object?> rows) {
    final buf = StringBuffer();
    for (final row in rows) {
      final map = _asMap(row);
      if (map == null) continue;
      final lyric = _unescape('${map['lineLyric'] ?? ''}').trim();
      if (lyric.isEmpty) continue;
      final seconds = double.tryParse('${map['time'] ?? ''}') ?? 0;
      final centis = (seconds * 100).round();
      final mm = (centis ~/ 6000).toString().padLeft(2, '0');
      final ss = ((centis ~/ 100) % 60).toString().padLeft(2, '0');
      final cc = (centis % 100).toString().padLeft(2, '0');
      buf.writeln('[$mm:$ss.$cc]$lyric');
    }
    return buf.toString();
  }

  /// 取一个正则的全部捕获组。
  static List<String> _pickAll(String text, String pattern) {
    final rx = RegExp(pattern);
    final out = <String>[];
    for (final m in rx.allMatches(text)) {
      out.add(m.group(1) ?? '');
    }
    return out;
  }

  /// 酷我把 HTML 实体原样塞在正文里，不还原搜索词就成了 `晴天&nbsp;(KTV版伴奏)`。
  static String _unescape(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");

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

  static Object? _decode(Object? data) {
    if (data is String) {
      final text = data.trim();
      if (text.isEmpty) return null;
      // 该接口会在 JSON 前面先甩几行空行，所以要按首个 `{` 截断后再解析。
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start < 0 || end <= start) return null;
      try {
        return jsonDecode(text.substring(start, end + 1));
      } catch (_) {
        return null;
      }
    }
    return data;
  }

  static Map<String, Object?>? _asMap(Object? data) {
    if (data is Map) return data.cast<String, Object?>();
    return null;
  }

  // ---------------------------------------------------------------- 测试入口
  //
  // 下面四个都是纯函数（不碰网络），但酷我的解析是**整个源里最容易悄悄坏掉**
  // 的地方：搜索接口返回非法 JSON、歌词时间是秒、正文带 HTML 实体。
  // 单独开测试入口，好让 `test/` 能锁住行为，不必真联网。

  @visibleForTesting
  static Object? decodeForTest(Object? data) => _decode(data);

  @visibleForTesting
  static String buildLrcForTest(List<Object?> rows) => _buildLrc(rows);

  @visibleForTesting
  static List<String> pickAllForTest(String text, String pattern) =>
      _pickAll(text, pattern);

  @visibleForTesting
  static String unescapeForTest(String s) => _unescape(s);
}

/// 搜索接口的一条候选。
class _KuwoSong {
  const _KuwoSong({
    required this.id,
    required this.title,
    required this.artist,
    required this.durationMs,
    required this.score,
  });

  final String id;
  final String title;
  final String artist;
  final int? durationMs;
  final int score;
}
