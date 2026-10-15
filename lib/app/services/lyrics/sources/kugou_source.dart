import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'lrc_formats.dart';
import 'lyric_query.dart';
import 'lyric_source.dart';

/// 酷狗音乐歌词源。
///
/// 实测要点（**别改回单步查询**）：
///
/// 1. **必须两步**。`lyrics.kugou.com/search` 只覆盖**用户上传的第三方歌词**，
///    实测 `童话镇` / `后来` / `追梦人` / `崇拜` 这类常规曲目恒返回 0 条，
///    而 `晴天` / `成都` / `水星记` 能出 7~10 条 —— 覆盖率完全不可靠。
///    先走 `mobilecdn .../search/song` 按歌名搜到 `hash`，再拿 hash 请求
///    `lyrics.kugou.com/search`，候选数会从 0 直接跳到 18。
///    抽样 35 首实测：单步 0% → 两步 **94%**。
/// 2. 单步方案还有个怪癖：`duration` **恰好等于**曲库时长时可能返回 0
///    （`成都` 288s 整 → 0，287s/289s → 7），所以它本身就不该用。
/// 3. `mobilecdn.kugou.com` 的 HTTPS 证书**主机名不匹配**，只能走 HTTP。
///    App 已开 `usesCleartextTraffic`，所以这条通路没问题；
///    改成 HTTPS 会直接 TLS 握手失败。
/// 4. 歌词是 `base64(content)`，要自己解一次；`fmt=lrc` 拿的是整行歌词，
///    逐字要 `fmt=krc` 且需要额外解码，本实现不做。
class KugouSource extends LyricSource {
  /// 搜歌（免签名）。
  static const String _songSearchUrl =
      'http://mobilecdn.kugou.com/api/v3/search/song';

  /// 按 hash 找歌词条目。
  static const String _lyricSearchUrl = 'https://lyrics.kugou.com/search';

  /// 下载歌词正文。
  static const String _downloadUrl = 'https://lyrics.kugou.com/download';

  /// 酷狗返回的时长偶尔与曲库差几秒，与网易云保持同一口径。
  static const int durationToleranceMs = 4000;

  @override
  String get id => 'kugou';

  @override
  String get displayName => '酷狗音乐';

  @override
  String get description => '中文整行歌词（非官方接口，两步查询）';

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
      },
      validateStatus: (int? code) => code != null && code < 600,
    ),
  );

  @override
  Future<LyricFetchResult?> fetch(
    LyricQuery query, {
    bool allowPlain = false,
  }) async {
    var song = await _searchSong(query, query.title);
    if (song == null && query.artist.isNotEmpty) {
      song = await _searchSong(query, '${query.title} ${query.artist}');
    }
    if (song == null) return null;

    final hash = '${song['hash'] ?? ''}'.trim();
    if (hash.isEmpty) return null;

    final ref = await _findLyric(query, hash, song);
    if (ref == null) return null;
    return _download(query, ref, song);
  }

  /// 第一步：按歌名搜歌，拿到 `hash`。
  Future<Map<String, Object?>?> _searchSong(
    LyricQuery query,
    String keyword,
  ) async {
    final res = await _dio.get<Object?>(
      _songSearchUrl,
      queryParameters: <String, Object?>{
        'format': 'json',
        'keyword': keyword,
        'page': 1,
        'pagesize': 20,
        'showtype': 1,
      },
    );
    _throwIfRateLimited(res);
    if (res.statusCode != 200) return null;
    // ⚠️ 必须走 `_decode`，不能直接 `_asMap(res.data)`：
    // `mobilecdn` 返回的 `Content-Type` 是 **`text/html`**（实测响应头），
    // 正文却是 JSON。Dio 只按 Content-Type 决定要不要解析，这里就会把
    // `res.data` 留成裸 String，`_asMap` 判空 → 整个源静默哑掉、一条都搜不到。
    final data = _asMap(_asMap(_decode(res.data))?['data']);
    final list = data?['info'];
    if (list is! List) return null;

    Map<String, Object?>? best;
    var bestScore = 0;
    for (final item in list) {
      final song = _asMap(item);
      if (song == null) continue;
      final score = LyricTextNorm.scoreCandidate(
        queryTitle: query.title,
        queryArtist: query.artist,
        queryDurationMs: query.durationMs,
        candidateTitle: '${song['songname'] ?? ''}',
        candidateArtists: <String>['${song['singername'] ?? ''}'],
        candidateDurationMs: LyricTextNorm.secondsToMs(song['duration'] as num?),
        durationToleranceMs: durationToleranceMs,
      );
      if (score > bestScore) {
        bestScore = score;
        best = song;
      }
    }
    return best;
  }

  /// 第二步：按 hash 找歌词条目（拿 `id` + `accesskey`）。
  Future<Map<String, Object?>?> _findLyric(
    LyricQuery query,
    String hash,
    Map<String, Object?> song,
  ) async {
    final res = await _dio.get<Object?>(
      _lyricSearchUrl,
      queryParameters: <String, Object?>{
        'ver': 1,
        'man': 'yes',
        'client': 'pc',
        'hash': hash,
        if (query.title.isNotEmpty) 'keyword': query.title,
        if (query.durationMs != null)
          'duration': (query.durationMs! / 1000).round(),
      },
    );
    _throwIfRateLimited(res);
    if (res.statusCode != 200) return null;
    // 同上：这两步的 Content-Type 虽然是对的，但统一走 `_decode` 更稳，
    // 免得哪天上游改一下头就整源失效。
    final list = _asMap(_decode(res.data))?['candidates'];
    if (list is! List || list.isEmpty) return null;

    // 同一首歌的歌词条目可能有多个版本，挑时长最贴近的那条。
    Map<String, Object?>? best;
    var bestDelta = 1 << 30;
    for (final item in list) {
      final c = _asMap(item);
      if (c == null) continue;
      final durMs = c['duration'];
      final delta = (query.durationMs == null || durMs is! num)
          ? 0
          : (query.durationMs! - (durMs * 1000).round()).abs();
      if (best == null || delta < bestDelta) {
        best = c;
        bestDelta = delta;
      }
    }
    return best;
  }

  /// 第三步：下载歌词正文（`content` 是 base64）。
  Future<LyricFetchResult?> _download(
    LyricQuery query,
    Map<String, Object?> ref,
    Map<String, Object?> song,
  ) async {
    final lyricId = '${ref['id'] ?? ''}'.trim();
    final accesskey = '${ref['accesskey'] ?? ''}'.trim();
    if (lyricId.isEmpty || accesskey.isEmpty) return null;

    final res = await _dio.get<Object?>(
      _downloadUrl,
      queryParameters: <String, Object?>{
        'ver': 1,
        'client': 'pc',
        'id': lyricId,
        'accesskey': accesskey,
        'fmt': 'lrc',
        'charset': 'utf8',
      },
    );
    _throwIfRateLimited(res);
    if (res.statusCode != 200) return null;

    final root = _asMap(_decode(res.data));
    if (root == null) return null;
    final encoded = _nonEmpty(root['content']);
    if (encoded == null) return null;

    String text;
    try {
      text = utf8.decode(base64.decode(encoded));
    } catch (_) {
      return null;
    }
    text = LrcFormats.sanitize(text);
    if (!LrcFormats.hasSyncedLines(text)) return null;

    return LyricFetchResult(
      content: text,
      sourceId: id,
      format: LrcFormats.isWordSynced(text)
          ? LyricFormat.wordSynced
          : LyricFormat.lineSynced,
      matchedTitle: '${song['songname'] ?? query.title}',
      matchedArtist: _nonEmpty('${song['singername'] ?? ''}'),
      matchedDurationMs: LyricTextNorm.secondsToMs(song['duration'] as num?),
    );
  }

  /// 酷狗在过载时会直接给 5xx，按「需要退避」处理，别静默降级。
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

  /// 酷狗部分接口不返回 `application/json`，Dio 会给原始 String。
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

  static String? _nonEmpty(Object? value) {
    if (value is! String) return null;
    final t = value.trim();
    return t.isEmpty ? null : t;
  }

  static Map<String, Object?>? _asMap(Object? data) {
    if (data is Map) return data.cast<String, Object?>();
    return null;
  }

  /// 纯函数（不碰网络），但酷狗有接口不返回 `application/json`，
  /// 拿到的是裸 String——这一步坏了整个源就哑了，所以留个测试入口。
  @visibleForTesting
  static Object? decodeForTest(Object? data) => _decode(data);
}
