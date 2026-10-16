import 'package:flutter_test/flutter_test.dart';
import 'package:fnmusic/app/services/lyrics/lyrics_parser.dart';

/// LRC 的 `[offset:±ms]` 是**校正量**，不是普通元数据行。
///
/// 原实现把它和 `[ti:]` `[ar:]` 一起 `continue` 掉了：文件里明明写了校正量，
/// 我们却把整首歌渲染成偏移的，而且没有任何提示让用户知道。
///
/// 为什么这对本曲库是真问题：翻唱 / 现场 / 自制录音棚版与原版的起唱点往往不同，
/// 这类歌词文件普遍靠 `[offset:]` 把时间轴对齐；而这个曲库的歌词全部是联网刮来的
/// 翻唱版本，正是最容易带 offset 的那一类。
void main() {
  group('LRC [offset:] 校正量', () {
    test('正偏移：整首歌的时间戳一起延后', () {
      const String lrc = '[offset:500]\n'
          '[00:01.000]第一句\n'
          '[00:03.000]第二句\n';

      final lines = LyricsParser.parseLrc(lrc);

      expect(lines.length, 2);
      expect(lines[0].time, const Duration(milliseconds: 1500));
      expect(lines[1].time, const Duration(milliseconds: 3500));
    });

    test('负偏移：整首歌的时间戳一起提前', () {
      const String lrc = '[offset:-500]\n'
          '[00:01.000]第一句\n'
          '[00:03.000]第二句\n';

      final lines = LyricsParser.parseLrc(lrc);

      expect(lines[0].time, const Duration(milliseconds: 500));
      expect(lines[1].time, const Duration(milliseconds: 2500));
    });

    test('负偏移不把开头几行钳到 0', () {
      // 刻意的设计取舍：钳到 0 会让多行撞在同一个时间戳上，被去重逻辑当成重复行
      // 丢掉 —— 那是真的丢数据。负数只是个起点，渲染按进度推进，不会出问题。
      const String lrc = '[offset:-2000]\n'
          '[00:00.100]第一句\n'
          '[00:00.300]第二句\n'
          '[00:02.000]第三句\n';

      final lines = LyricsParser.parseLrc(lrc);

      expect(lines.length, 3);
      expect(lines[0].time, const Duration(milliseconds: -1900));
      expect(lines[1].time, const Duration(milliseconds: -1700));
      expect(lines[2].time, Duration.zero);
    });

    test('带正号的偏移也认', () {
      const String lrc = '[offset:+250]\n[00:01.000]甲\n';
      expect(
        LyricsParser.parseLrc(lrc).first.time,
        const Duration(milliseconds: 1250),
      );
    });

    test('没有 offset 标签时时间戳原样', () {
      const String lrc = '[00:01.000]第一句\n';
      expect(
        LyricsParser.parseLrc(lrc).first.time,
        const Duration(seconds: 1),
      );
    });

    test('offset 值缺失或非法时按 0 处理', () {
      for (final String raw in <String>[
        '[offset:]\n[00:01.000]甲\n',
        '[offset:abc]\n[00:01.000]甲\n',
      ]) {
        expect(
          LyricsParser.parseLrc(raw).first.time,
          const Duration(seconds: 1),
          reason: raw,
        );
      }
    });
  });

  group('buildModelFromRaw 同样应用 offset', () {
    test('整行歌词整体偏移', () {
      const String lrc = '[offset:500]\n'
          '[00:01.000]第一句\n'
          '[00:03.000]第二句\n';

      final model = LyricsParser.buildModelFromRaw(lrc, predictDuration: false);

      expect(model.lines.length, 2);
      expect(model.lines.first.start, const Duration(milliseconds: 1500));
      expect(model.lines.last.start, const Duration(milliseconds: 3500));
    });

    test('增强型逐字行（一行多个时间戳）连同逐字词一起偏移', () {
      const String lrc = '[offset:1000]\n[00:01.000]你[00:01.500]好[00:02.000]\n';

      final model = LyricsParser.buildModelFromRaw(lrc, predictDuration: false);

      expect(model.lines.length, 1);
      expect(model.lines.first.start, const Duration(seconds: 2));
      expect(model.lines.first.words?.first.start, const Duration(seconds: 2));
    });
  });

  group('元数据行不会被当成歌词', () {
    test('带缩进的元数据行也要被跳过', () {
      // 这是原来就存在的一个小毛病：判据用的是 `^\[`，前面多一个空格就漏了，
      // 于是 `[offset:500]` 会以「一句歌词」的形态出现在屏幕上。
      const String lrc = '[offset:500]\n'
          ' [ti:标题]\n'
          '  [00:01.000]第一句\n';

      final lines = LyricsParser.parseLrc(lrc);

      expect(lines.where((l) => l.text.contains('offset')), isEmpty);
      expect(lines.where((l) => l.text.contains('ti:')), isEmpty);
      expect(lines.length, 1);
      expect(lines.first.time, const Duration(milliseconds: 1500));
    });

    test('ti/ar/al/by 一律跳过', () {
      const String lrc = '[ti:歌名]\n'
          '[ar:歌手]\n'
          '[al:专辑]\n'
          '[by:某人]\n'
          '[00:01.000]正文\n';

      final lines = LyricsParser.parseLrc(lrc);

      expect(lines.length, 1);
      expect(lines.first.text, '正文');
    });
  });
}
