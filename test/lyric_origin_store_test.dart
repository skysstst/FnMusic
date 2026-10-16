import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnmusic/app/services/lyrics/lyric_origin.dart';
import 'package:fnmusic/app/services/lyrics/lyrics_repository.dart';
import 'package:fnmusic/app/services/lyrics/online_lyric_source.dart';

/// 「这份歌词是哪来的」这条线索的记录与读取。
///
/// 它本身不影响歌词能不能显示，但**错了会静默骗人** —— 界面上写着「来自酷狗」而
/// 实际是别的源、或者指向一份早就删掉的歌词。所以哪怕逻辑简单，也值得钉住。
void main() {
  late Directory tmp;
  late String path;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fnmusic_origin_test');
    path = '${tmp.path}${Platform.pathSeparator}_origins.json';
    LyricOriginStore.instance.resetForTest();
    LyricOriginStore.pathOverride = path;
  });

  tearDown(() async {
    LyricOriginStore.pathOverride = null;
    LyricOriginStore.instance.resetForTest();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  LyricOrigin sample({
    String sourceId = 'kugou',
    int atMs = 1700000000000,
  }) {
    return LyricOrigin(
      sourceId: sourceId,
      at: DateTime.fromMillisecondsSinceEpoch(atMs),
      matchedTitle: '晴天',
      matchedArtist: '周杰伦',
      matchedDurationMs: 269000,
      deltaMs: 4573,
      format: 'lineSynced',
    );
  }

  group('LyricOrigin', () {
    test('JSON 往返不丢字段', () {
      final LyricOrigin origin = sample();
      final LyricOrigin? back = LyricOrigin.fromJson(origin.toJson());

      expect(back, isNotNull);
      expect(back!.sourceId, 'kugou');
      expect(back.matchedTitle, '晴天');
      expect(back.matchedArtist, '周杰伦');
      expect(back.matchedDurationMs, 269000);
      expect(back.deltaMs, 4573);
      expect(back.format, 'lineSynced');
      expect(back.at.millisecondsSinceEpoch, 1700000000000);
    });

    test('可选字段为 null 时也能往返（不写出空键）', () {
      final LyricOrigin origin = LyricOrigin(
        sourceId: 'lrclib',
        at: DateTime.fromMillisecondsSinceEpoch(1),
      );
      final Map<String, Object?> json = origin.toJson();

      expect(json.containsKey('mt'), isFalse);
      expect(json.containsKey('delta'), isFalse);
      final LyricOrigin? back = LyricOrigin.fromJson(json);
      expect(back?.matchedTitle, isNull);
      expect(back?.deltaMs, isNull);
    });

    test('结构不对的条目一律丢弃而不是抛异常', () {
      expect(LyricOrigin.fromJson(null), isNull);
      expect(LyricOrigin.fromJson('不是 map'), isNull);
      expect(LyricOrigin.fromJson(<String, Object?>{}), isNull);
      expect(
        LyricOrigin.fromJson(<String, Object?>{'at': 1}),
        isNull,
        reason: '缺 source',
      );
      expect(
        LyricOrigin.fromJson(<String, Object?>{'source': 'kugou'}),
        isNull,
        reason: '缺时间戳',
      );
      expect(
        LyricOrigin.fromJson(<String, Object?>{'source': '', 'at': 1}),
        isNull,
        reason: 'source 为空串',
      );
    });
  });

  group('LyricOriginStore', () {
    test('写入后能读回，且重新读盘仍在（模拟重启）', () async {
      await LyricOriginStore.instance.put('guid-1', sample());

      expect(await LyricOriginStore.instance.count(), 1);
      final LyricOrigin? read = await LyricOriginStore.instance.get('guid-1');
      expect(read?.sourceId, 'kugou');
      expect(read?.matchedArtist, '周杰伦');

      LyricOriginStore.instance.resetForTest();
      final LyricOrigin? again = await LyricOriginStore.instance.get('guid-1');
      expect(again?.matchedTitle, '晴天');
      expect(again?.deltaMs, 4573);
    });

    test('删掉某首歌后不再返回，其余不受影响', () async {
      await LyricOriginStore.instance.put('a', sample(sourceId: 'kugou'));
      await LyricOriginStore.instance.put('b', sample(sourceId: 'qqmusic'));

      await LyricOriginStore.instance.remove('a');

      expect(await LyricOriginStore.instance.get('a'), isNull);
      expect((await LyricOriginStore.instance.get('b'))?.sourceId, 'qqmusic');
      expect(await LyricOriginStore.instance.count(), 1);
    });

    test('clear 清空全部', () async {
      await LyricOriginStore.instance.put('a', sample());
      await LyricOriginStore.instance.put('b', sample());

      await LyricOriginStore.instance.clear();

      expect(await LyricOriginStore.instance.count(), 0);
      expect(await LyricOriginStore.instance.get('a'), isNull);
    });

    test('文件不存在时读不到、也不报错', () async {
      LyricOriginStore.instance.resetForTest();
      expect(await LyricOriginStore.instance.get('nobody'), isNull);
      expect(await LyricOriginStore.instance.count(), 0);
    });

    test('文件损坏时当空处理，不抛异常', () async {
      await File(path).writeAsString('{ 这不是 json');
      LyricOriginStore.instance.resetForTest();

      expect(await LyricOriginStore.instance.get('x'), isNull);
      expect(await LyricOriginStore.instance.count(), 0);
    });

    test('坏条目被丢掉，好条目照常保留', () async {
      await File(path).writeAsString(
        json.encode(<String, Object?>{
          'good': <String, Object?>{'source': 'qqmusic', 'at': 1700000000000},
          'no-source': <String, Object?>{'at': 1700000000000},
          'no-at': <String, Object?>{'source': 'kuwo'},
          'not-a-map': '字符串',
        }),
      );
      LyricOriginStore.instance.resetForTest();

      expect(await LyricOriginStore.instance.count(), 1);
      expect(
        (await LyricOriginStore.instance.get('good'))?.sourceId,
        'qqmusic',
      );
    });

    test('目录不存在时会自动建出来', () async {
      final String nested =
          '${tmp.path}${Platform.pathSeparator}还没建过${Platform.pathSeparator}'
          '${LyricOriginStore.fileName}';
      LyricOriginStore.pathOverride = nested;
      LyricOriginStore.instance.resetForTest();

      await LyricOriginStore.instance.put('g', sample());

      expect(await File(nested).exists(), isTrue);
      expect(await LyricOriginStore.instance.count(), 1);
    });
  });

  group('渠道 id → 人看的名字', () {
    test('已知渠道换成显示名，未知 id 原样返回', () {
      final OnlineLyricSource source = OnlineLyricSource.instance;
      final String firstId = source.sources.first.id;

      expect(source.displayNameFor(firstId), isNotEmpty);
      expect(
        source.displayNameFor(firstId),
        isNot(firstId),
        reason: '显示名不该等于 id',
      );
      // 渠道以后被移除时，历史记录里的旧 id 仍要能显示出来，不能变空白。
      expect(source.displayNameFor('已经删掉的渠道'), '已经删掉的渠道');
    });
  });

  group('缓存分层的目录名', () {
    test('两层目录名稳定（它们是磁盘上的约定，改了等于丢缓存）', () {
      expect(LyricsCacheLayer.nas.dirName, 'nas');
      expect(LyricsCacheLayer.online.dirName, 'online');
      expect(LyricsCacheLayer.values.length, 2);
    });
  });
}
