import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnmusic/app/services/lyrics/lyric_offset_store.dart';
import 'package:fnmusic/app/services/lyrics/lyrics_parser.dart';

/// 用户手动调的歌词时间轴偏移。
///
/// 这补上了 `[offset:]` 标签补不了的场景：标签只能表达**上游作者**的校正，
/// 而真正决定「这首歌的词对不对」的是**用户自己听着**的结果 —— 翻唱版、
/// 现场版、剪辑过的音频，偏移量每次都可能不一样，只能现场调。
void main() {
  group('手动偏移叠加在文件 offset 之上', () {
    test('只有手动偏移', () {
      const String lrc = '[00:01.000]第一句\n[00:03.000]第二句\n';

      final model = LyricsParser.buildModelFromRaw(
        lrc,
        predictDuration: false,
        manualOffset: const Duration(milliseconds: 500),
      );

      expect(model.lines.length, 2);
      expect(model.lines.first.start, const Duration(milliseconds: 1500));
      expect(model.lines.last.start, const Duration(milliseconds: 3500));
    });

    test('文件 offset 与手动偏移相加，不是互相覆盖', () {
      // 刻意的设计：文件里的 offset 是上游的判断，手动调整是用户听过之后的判断，
      // 后者只可能更贴近他要的东西。所以「上游说延 500，我听着还得再延 200」
      // 应该是 700，而不是二选一。
      const String lrc = '[offset:500]\n[00:01.000]第一句\n';

      final model = LyricsParser.buildModelFromRaw(
        lrc,
        predictDuration: false,
        manualOffset: const Duration(milliseconds: 200),
      );

      expect(model.lines.first.start, const Duration(milliseconds: 1700));
    });

    test('两者反向相减', () {
      const String lrc = '[offset:800]\n[00:01.000]第一句\n';

      final model = LyricsParser.buildModelFromRaw(
        lrc,
        predictDuration: false,
        manualOffset: const Duration(milliseconds: -1200),
      );

      expect(model.lines.first.start, const Duration(milliseconds: 600));
    });

    test('manualOffset 传 null 等于不调整', () {
      const String lrc = '[00:01.000]第一句\n';

      final withNull = LyricsParser.buildModelFromRaw(
        lrc,
        predictDuration: false,
      );
      final withZero = LyricsParser.buildModelFromRaw(
        lrc,
        predictDuration: false,
        manualOffset: Duration.zero,
      );

      expect(withNull.lines.first.start, const Duration(seconds: 1));
      expect(withZero.lines.first.start, const Duration(seconds: 1));
    });

    test('逐字行的字级时间戳也一起偏移', () {
      const String lrc = '[00:01.000]你[00:01.500]好[00:02.000]\n';

      final model = LyricsParser.buildModelFromRaw(
        lrc,
        predictDuration: false,
        manualOffset: const Duration(milliseconds: 400),
      );

      expect(model.lines.first.start, const Duration(milliseconds: 1400));
      expect(
        model.lines.first.words?.first.start,
        const Duration(milliseconds: 1400),
      );
    });

    test('负偏移不会被钳到 0（钳了会丢行）', () {
      const String lrc = '[00:00.100]甲\n[00:00.300]乙\n[00:02.000]丙\n';

      final model = LyricsParser.buildModelFromRaw(
        lrc,
        predictDuration: false,
        manualOffset: const Duration(milliseconds: -2000),
      );

      // 钳到 0 会让前两行撞在同一时间戳上被去重丢掉 —— 那是真的丢数据。
      expect(model.lines.length, 3);
      expect(model.lines.first.start, const Duration(milliseconds: -1900));
    });

    test('纯文本退化路径也平移，且末行仍盖到歌尾', () {
      // 没有时间戳的歌词会按歌曲长度均分时间轴；用户既然调了偏移就该整体平移，
      // 而末行原本锚在 songDuration 上，平移后必须同步平移，否则会越界。
      const String lrc = '甲\n乙\n丙\n';

      final model = LyricsParser.buildModelFromRaw(
        lrc,
        songDuration: const Duration(seconds: 30),
        predictDuration: false,
        manualOffset: const Duration(seconds: 3),
      );

      expect(model.lines.length, 3);
      expect(model.lines.first.start, const Duration(seconds: 3));
      expect(model.lines.last.end, const Duration(seconds: 33));
    });
  });

  group('LyricOffsetStore', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fnmusic_offset_test');
      LyricOffsetStore.pathOverride = '${tmp.path}${Platform.pathSeparator}o.json';
      LyricOffsetStore.instance.resetForTest();
    });

    tearDown(() async {
      LyricOffsetStore.pathOverride = null;
      LyricOffsetStore.instance.resetForTest();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('没有记录时返回 null（区分「没调过」与「调成 0」）', () async {
      expect(await LyricOffsetStore.instance.get('a'), isNull);
    });

    test('put/get 往返', () async {
      await LyricOffsetStore.instance.put('a', -750);
      expect(await LyricOffsetStore.instance.get('a'), -750);
    });

    test('存 0 等于删记录，不在文件里堆 0 值', () async {
      await LyricOffsetStore.instance.put('a', 500);
      await LyricOffsetStore.instance.put('a', 0);
      expect(await LyricOffsetStore.instance.get('a'), isNull);
      expect(await LyricOffsetStore.instance.count(), 0);
    });

    test('remove 生效', () async {
      await LyricOffsetStore.instance.put('a', 300);
      await LyricOffsetStore.instance.remove('a');
      expect(await LyricOffsetStore.instance.get('a'), isNull);
    });

    test('超过上限的值被钳位', () async {
      // 滑杆是连续控件，一次手滑就能到几千毫秒，而超过 10 分钟基本等于
      // 「配错版本了」—— 那种情况该重新匹配而不是硬挪时间轴。
      await LyricOffsetStore.instance.put('a', 99999999);
      expect(await LyricOffsetStore.instance.get('a'), LyricOffsetStore.maxAbsMs);

      await LyricOffsetStore.instance.put('b', -99999999);
      expect(await LyricOffsetStore.instance.get('b'), -LyricOffsetStore.maxAbsMs);
    });

    test('损坏的记录文件当作空的', () async {
      final file = File(LyricOffsetStore.pathOverride!);
      await file.writeAsString('{ this is not json');
      LyricOffsetStore.instance.resetForTest();
      expect(await LyricOffsetStore.instance.get('a'), isNull);
    });

    test('记录能落盘并在重载后读回', () async {
      await LyricOffsetStore.instance.put('a', 1200);
      LyricOffsetStore.instance.resetForTest();
      expect(await LyricOffsetStore.instance.get('a'), 1200);
    });

    test('clear 清空全部', () async {
      await LyricOffsetStore.instance.put('a', 100);
      await LyricOffsetStore.instance.put('b', 200);
      await LyricOffsetStore.instance.clear();
      expect(await LyricOffsetStore.instance.count(), 0);
    });
  });
}