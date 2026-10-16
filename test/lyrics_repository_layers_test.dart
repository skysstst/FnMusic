import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnmusic/app/services/lyrics/lyrics_repository.dart';
import 'package:path/path.dart' as p;

/// 歌词缓存分层要守住的核心保证。
///
/// 这里出过的事故值得写下来：在线刮到的歌词与音乐库自带的歌词原先写进**同一个**
/// 文件，而读取是「缓存优先、命中即返回」，于是先落地的那份会把后来的永久挡住 ——
/// 音乐库里后来补了正式歌词也看不见，除非清空全部歌词缓存。
///
/// 为什么对本曲库格外要紧：它的歌词几乎全部是联网刮来的（实测两个歌单 262 条曲目
/// 本地歌词 0 首），所以「在线歌词占住了位置」是常态，不是例外。
void main() {
  late Directory tmp;
  late LyricsRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fnmusic_lyrics_layers');
    LyricsRepository.supportDirOverride = tmp.path;
    repo = LyricsRepository();
  });

  tearDown(() async {
    LyricsRepository.supportDirOverride = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 与实现里的 FNV-1a 64 位散列一致。
  ///
  /// **故意在测试里重写一遍**：它是磁盘上的命名约定，一旦漂移，所有人已缓存的
  /// 歌词都会「突然消失」，而那种故障从界面上完全看不出来。
  String cacheKey(String songId) {
    final bytes = utf8.encode(songId);
    const int offsetBasis = 0xcbf29ce484222325;
    const int prime = 0x100000001b3;
    const int mask64 = 0xFFFFFFFFFFFFFFFF;
    var hash = offsetBasis;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * prime) & mask64;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  File layerFile(LyricsCacheLayer layer, String guid) => File(
        p.join(tmp.path, 'lyrics', layer.dirName, '${cacheKey(guid)}.lrc'),
      );

  File legacyFile(String guid) =>
      File(p.join(tmp.path, 'lyrics', '${cacheKey(guid)}.lrc'));

  group('两层互不干扰', () {
    test('音乐库歌词只落在 nas，在线歌词只落在 online', () async {
      await repo.saveNasLrc('g1', '[00:01.000]库里的词');
      await repo.saveOnlineLrc('g2', '[00:01.000]网上刮的词');

      expect(await layerFile(LyricsCacheLayer.nas, 'g1').exists(), isTrue);
      expect(await layerFile(LyricsCacheLayer.online, 'g1').exists(), isFalse);
      expect(await layerFile(LyricsCacheLayer.online, 'g2').exists(), isTrue);
      expect(await layerFile(LyricsCacheLayer.nas, 'g2').exists(), isFalse);

      expect(await repo.loadNasLrc('g1'), contains('库里的词'));
      expect(await repo.loadNasLrc('g2'), isNull);
      expect(await repo.loadOnlineLrc('g2'), contains('网上刮的词'));
      expect(await repo.loadOnlineLrc('g1'), isNull);
    });

    test('同一个 guid 可以两层同时存在，各读各的', () async {
      await repo.saveNasLrc('g', '音乐库的词');
      await repo.saveOnlineLrc('g', '在线刮的词');

      expect(await repo.loadNasLrc('g'), '音乐库的词');
      expect(await repo.loadOnlineLrc('g'), '在线刮的词');
    });
  });

  group('清除', () {
    test('不指定层级时两层都清', () async {
      await repo.saveNasLrc('g', 'A');
      await repo.saveOnlineLrc('g', 'B');

      await repo.removeCachedLrc('g');

      expect(await repo.loadNasLrc('g'), isNull);
      expect(await repo.loadOnlineLrc('g'), isNull);
    });

    test('指定层级时只清那一层', () async {
      await repo.saveNasLrc('g', 'A');
      await repo.saveOnlineLrc('g', 'B');

      await repo.removeCachedLrc('g', layer: LyricsCacheLayer.online);

      expect(await repo.loadNasLrc('g'), 'A');
      expect(await repo.loadOnlineLrc('g'), isNull);
    });

    test('清某一层不影响另一层', () async {
      await repo.saveNasLrc('g1', 'A');
      await repo.saveOnlineLrc('g2', 'B');

      await repo.clearLayer(LyricsCacheLayer.nas);

      expect(await repo.loadNasLrc('g1'), isNull);
      expect(await repo.loadOnlineLrc('g2'), 'B');
    });
  });

  group('统计', () {
    test('首数只算歌词，不把来源记录算进去', () async {
      final File origins =
          File(p.join(tmp.path, 'lyrics', 'online', '_origins.json'));
      await origins.parent.create(recursive: true);
      await origins.writeAsString('{"a":{"source":"kugou","at":1}}');
      await repo.saveOnlineLrc('g1', 'x' * 100);

      expect(await repo.layerFileCount(LyricsCacheLayer.online), 1);
      expect(await repo.layerSize(LyricsCacheLayer.online), greaterThan(100));
    });

    test('空目录返回 0 而不是报错', () async {
      expect(await repo.layerFileCount(LyricsCacheLayer.nas), 0);
      expect(await repo.layerSize(LyricsCacheLayer.nas), 0);
    });
  });

  group('写入', () {
    test('默认不覆盖已存在的同层缓存', () async {
      await repo.saveOnlineLrc('g', '第一次');
      await repo.saveOnlineLrc('g', '第二次');

      expect(await repo.loadOnlineLrc('g'), '第一次');
    });

    test('overwrite: true 时才覆盖', () async {
      await repo.saveOnlineLrc('g', '第一次');
      await repo.saveOnlineLrc('g', '第二次', overwrite: true);

      expect(await repo.loadOnlineLrc('g'), '第二次');
    });

    test('空内容不写', () async {
      await repo.saveOnlineLrc('g', '   \n ');

      expect(await repo.loadOnlineLrc('g'), isNull);
    });
  });

  group('历史扁平缓存迁移', () {
    test('旧的 lyrics/*.lrc 被搬进 online 层，不再留在根目录', () async {
      await legacyFile('old').parent.create(recursive: true);
      await legacyFile('old').writeAsString('很久以前刮的词');

      expect(await repo.loadOnlineLrc('old'), '很久以前刮的词');
      expect(await legacyFile('old').exists(), isFalse);
      expect(await layerFile(LyricsCacheLayer.online, 'old').exists(), isTrue);
    });

    test('迁移不会把旧文件当成音乐库歌词', () async {
      await legacyFile('old').parent.create(recursive: true);
      await legacyFile('old').writeAsString('很久以前刮的词');

      expect(
        await repo.loadNasLrc('old'),
        isNull,
        reason: '旧文件来源已无法区分，一律按在线处理 —— 这样音乐库之后补的词不会被压住',
      );
    });

    test('目标已存在时丢掉旧副本，不覆盖新的', () async {
      await repo.saveOnlineLrc('old', '新的');
      await legacyFile('old').parent.create(recursive: true);
      await legacyFile('old').writeAsString('旧的');

      // 换一个实例，模拟「下次启动」才看到遗留文件。
      expect(await LyricsRepository().loadOnlineLrc('old'), '新的');
      expect(await legacyFile('old').exists(), isFalse);
    });

    test('迁移幂等：跑两次结果一样', () async {
      await legacyFile('old').parent.create(recursive: true);
      await legacyFile('old').writeAsString('词');

      await repo.loadOnlineLrc('old');
      await LyricsRepository().loadOnlineLrc('old');

      expect(await repo.loadOnlineLrc('old'), '词');
      expect(await repo.layerFileCount(LyricsCacheLayer.online), 1);
    });

    test('清空在线层会把迁过来的旧文件一起带走', () async {
      await legacyFile('old').parent.create(recursive: true);
      await legacyFile('old').writeAsString('词');

      await repo.clearLayer(LyricsCacheLayer.online);

      expect(await legacyFile('old').exists(), isFalse);
      expect(await repo.loadOnlineLrc('old'), isNull);
    });
  });
}
