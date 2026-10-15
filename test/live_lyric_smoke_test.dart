import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnmusic/app/services/lyrics/sources/amll_source.dart';
import 'package:fnmusic/app/services/lyrics/sources/kugou_source.dart';
import 'package:fnmusic/app/services/lyrics/sources/kuwo_source.dart';
import 'package:fnmusic/app/services/lyrics/sources/lyric_query.dart';
import 'package:fnmusic/app/services/lyrics/sources/lyric_source.dart';
import 'package:fnmusic/app/services/lyrics/sources/lrclib_source.dart';
import 'package:fnmusic/app/services/lyrics/sources/netease_source.dart';
import 'package:fnmusic/app/services/lyrics/sources/qqmusic_source.dart';
import 'package:fnmusic/app/state/song_state.dart';

/// 真机网络冒烟测试：用**曲库里真实的歌**去打真实接口。
///
/// 不打桩、不 mock —— 目的就是回答「这个翻唱曲库到底能不能刮到词」。
/// 跑法：`flutter test test/live_lyric_smoke_test.dart`
///
/// 两个歌单各取几首，覆盖这个曲库最难的三档：
/// 1. 繁体标题（曲库 `阿婆說` / 歌词库 `阿婆说`）；
/// 2. 歌手是翻唱者（陈一发儿），网易云 / QQ 上只有原唱条目；
/// 3. **标题自带「 - 歌手」后缀**（`宝贝 - 陈一发儿`）——第二个歌单的普遍格式，
///    依赖 [LyricQuery.fromSong] 把它剥干净。
///
/// 时长取曲库实际显示值，故意与主流发行版有出入 —— 用来验证
/// 「民间翻唱时长和主流版不一样」也被容差覆盖到了。
///
/// 这里刻意**走 `LyricQuery.fromSong` 而不是手搓 LyricQuery**，
/// 因为标题清洗（繁转简、剥歌手尾巴）正是最容易出错的一环。
class _LibSong {
  const _LibSong(this.title, this.artist, this.durationMs, {this.playlist = '1'});

  final String title;
  final String artist;
  final int durationMs;
  final String playlist;
}

void main() {
  // 联网测试默认**跳过**，要跑必须显式开门：
  //
  //     LIVE_NET=1 flutter test test/live_lyric_smoke_test.dart
  //
  // 为什么默认跳过：这个文件真的打第三方接口（QQ / 酷狗 / 酷我 / 网易云 /
  // LRCLIB / AMLL），无网环境下必红，频繁跑还会被限流；而本仓库的质量门是
  // `flutter test` 默认全绿。跳过它，CI 才不依赖外部网络。
  final bool live = Platform.environment['LIVE_NET'] == '1';
  const String skipMsg = '联网测试，未设置 LIVE_NET=1，已跳过';

  // Flutter 的测试 binding 会把进程内 HttpClient 全局替换成「所有请求一律 400」
  // 的假实现；这里要打真实网络，必须还原成真实实现。
  setUpAll(() {
    HttpOverrides.global = null;
  });

  final List<LyricSource> sources = <LyricSource>[
    LrclibSource(),
    NeteaseSource(),
    QqMusicSource(),
  ];

  const List<_LibSong> songs = <_LibSong>[
    // ── 歌单一《不爱喝热水_Spotify发行》：繁体标题、无歌手后缀 ──
    _LibSong('阿婆說', '陈一发儿', 247000, playlist: 'P1'),
    _LibSong('白山茶', '陈一发儿', 256000, playlist: 'P1'),
    _LibSong('不染', '陈一发儿', 273000, playlist: 'P1'),
    _LibSong('成都', '陈一发儿', 288000, playlist: 'P1'),
    _LibSong('匆匆', '陈一发儿', 300000, playlist: 'P1'),
    _LibSong('從前慢', '陈一发儿', 216000, playlist: 'P1'),
    // ── 歌单二《不爱喝热水_录音棚版》：标题自带「 - 歌手」后缀 ──
    _LibSong('宝贝 - 陈一发儿', '陈一发儿', 146000, playlist: 'P2'),
    _LibSong('Bizarre love triangle - 陈一发儿', '陈一发儿', 115000, playlist: 'P2'),
    _LibSong('City of Stars - 陈一发儿', '陈一发儿', 140000, playlist: 'P2'),
    _LibSong('打错了 - 陈一发儿', '陈一发儿', 185000, playlist: 'P2'),
    _LibSong('当你老了 - 陈一发儿', '陈一发儿', 195000, playlist: 'P2'),
  ];

  test('live：逐个源试这些歌，打印命中情况', () async {
    var hitSongs = 0;
    final Map<String, int> byPlaylist = <String, int>{};
    final Map<String, int> totalByPlaylist = <String, int>{};

    for (final _LibSong s in songs) {
      final LyricQuery q = LyricQuery.fromSong(SongEntity(
        guid: s.title,
        title: s.title,
        artistDisplay: s.artist,
        durationMs: s.durationMs,
      ));
      // ignore: avoid_print
      print('[QUERY][${s.playlist}] 曲库标题「${s.title}」 → 实际查询 '
          '「${q.title}」/「${q.artist}」/${q.durationMs}ms');

      final List<String> hits = <String>[];
      for (final LyricSource src in sources) {
        try {
          final LyricFetchResult? r = await src.fetch(q);
          if (r != null && r.content.trim().isNotEmpty) {
            hits.add(src.id);
            // ignore: avoid_print
            print('[HIT ] ${q.title} <- ${src.id}  '
                '匹配到「${r.matchedTitle}」/「${r.matchedArtist}」'
                '/${r.matchedDurationMs}ms  ${r.content.length} 字');
          } else {
            // ignore: avoid_print
            print('[MISS] ${q.title} - ${src.id}');
          }
        } catch (e) {
          // ignore: avoid_print
          print('[ERR ] ${q.title} - ${src.id}: ${e.toString().split('\n').first}');
        }
      }
      totalByPlaylist[s.playlist] = (totalByPlaylist[s.playlist] ?? 0) + 1;
      if (hits.isNotEmpty) {
        hitSongs++;
        byPlaylist[s.playlist] = (byPlaylist[s.playlist] ?? 0) + 1;
      }
      // ignore: avoid_print
      print('>>> [${s.playlist}] ${q.title}：'
          '${hits.isEmpty ? "全部落空" : hits.join(" + ")}');
      // ignore: avoid_print
      print('');
    }

    // ignore: avoid_print
    print('==== 汇总：$hitSongs / ${songs.length} 首至少命中一个源 ====');
    for (final String k in totalByPlaylist.keys) {
      // ignore: avoid_print
      print('     $k: ${byPlaylist[k] ?? 0} / ${totalByPlaylist[k]}');
    }
    expect(hitSongs, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 8)), skip: live ? null : skipMsg);

  test('live：六个渠道的探针歌逐个实跑（设置页「测试」按钮的后端）', () async {
    // 这是设置页每个渠道「测试」按钮走的同一条路。
    // 判定标准只有一条：**不许静默返回 null**。
    // `null` 的语义是「连上了、接口也正常应答，但连大众探针歌都没词」，
    // 也就是渠道改版——正是这个测试要守住的信号。被限流 / 索引没好都属于
    // 有明确例外类型的「暂时」，不算坏。
    //
    // 加这条的直接原因：酷狗曾经因为 `mobilecdn` 的 Content-Type 写成
    // `text/html`（正文却是 JSON），Dio 不解析、`_asMap` 判空，
    // 整个渠道**一条都搜不到却一声不响**。单测抓不到（要真联网 + 真响应头），
    // 只有这条能抓住。
    final List<LyricSource> all = <LyricSource>[
      QqMusicSource(),
      KugouSource(),
      KuwoSource(),
      NeteaseSource(),
      LrclibSource(),
      AmllTtmlDbSource(),
    ];

    final List<String> silentNulls = <String>[];
    for (final LyricSource src in all) {
      final LyricQuery q = src.probeQuery;
      try {
        final LyricFetchResult? r = await src.fetch(q);
        if (r == null || r.content.trim().isEmpty) {
          silentNulls.add(src.id);
          // ignore: avoid_print
          print('[PROBE-NULL] ${src.id} 探针《${q.title}》没取到词 —— 渠道可能改版');
        } else {
          // ignore: avoid_print
          print('[PROBE-OK  ] ${src.id.padRight(9)} '
              '${r.format.name} ${r.content.length} 字 '
              '命中「${r.matchedTitle}/${r.matchedArtist}」');
        }
      } on LyricRateLimitedException catch (e) {
        // ignore: avoid_print
        print('[PROBE-RATE] ${src.id.padRight(9)} 被限流（${e.retryAfter}）—— 属暂时，不算坏');
      } on LyricSourceNotReadyException catch (e) {
        // ignore: avoid_print
        print('[PROBE-WAIT] ${src.id.padRight(9)} ${e.message} —— 属暂时，不算坏');
      } catch (e) {
        // ignore: avoid_print
        print('[PROBE-ERR ] ${src.id.padRight(9)} ${e.toString().split('\n').first}');
      }
    }

    expect(
      silentNulls,
      isEmpty,
      reason: '这些渠道对大众探针歌静默返回了空，等于「测试」按钮永远测不出来：$silentNulls',
    );
  }, timeout: const Timeout(Duration(minutes: 6)), skip: live ? null : skipMsg);
}
