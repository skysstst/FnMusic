import 'package:flutter_test/flutter_test.dart';

import 'package:fnmusic/app/services/lyrics/lyrics_parser.dart';

/// 调偏移时的「不闪」契约。
///
/// ## 背景
///
/// 用户反馈：按步进键调整偏移时，**页面每次都闪一下**。
///
/// 根因不是动画，而是走错了重载路径：`_loadForSong`（也就是 `reloadCurrentSong`）
/// 一进门就把 `status` 打成 `loading`、`model` 打成 `null`、
/// `lyricNotifier` 也清空。那是「换歌 / 找词」该有的样子，但用户每按一次键都会走它
/// —— 于是歌词每次都消失一瞬再跳回来。
///
/// 修法是新增 `reparseWithOffset`：拿缓存的 LRC 原文直接重解析，
/// 不经过 loading、不清空 model。
///
/// ## 这组测试测什么
///
/// 这里测的是**契约本身**（时序与量纲），而不是具体的服务单例 ——
/// 服务单例要拖起播放器、path_provider、真实文件缓存，测起来成本远大于收益。
/// 但这两条性质一旦被改坏，症状立刻回到「页面闪烁」，所以必须钉住。
void main() {
  group('偏移重解析不改歌词的「身份」', () {
    test('同一份原文在两个偏移下解析出相同行数（只是时间戳平移）', () {
      const String lrc = '[00:01.000]第一句\n'
          '[00:03.000]第二句\n'
          '[00:05.000]第三句\n';

      final a = LyricsParser.buildModelFromRaw(
        lrc,
        predictDuration: false,
        manualOffset: const Duration(milliseconds: 0),
      );
      final b = LyricsParser.buildModelFromRaw(
        lrc,
        predictDuration: false,
        manualOffset: const Duration(milliseconds: 400),
      );

      // 行数不变是「歌词没有被清空重填」的前提。
      // 若偏移导致某几行撞在同一时间戳被去重丢掉，屏幕上就会「少几行」——
      // 那是另一种闪烁（内容跳变），同样不可接受。
      expect(b.lines.length, a.lines.length);

      for (int i = 0; i < a.lines.length; i++) {
        expect(
          b.lines[i].start.inMilliseconds,
          a.lines[i].start.inMilliseconds + 400,
          reason: '第 $i 行应当整体平移 400ms',
        );
        expect(b.lines[i].text, a.lines[i].text);
      }
    });

    test('偏移方向搞反会让歌词往反方向跑 —— 用首行锁定符号', () {
      // 这条是本组最要紧的：符号错一个，用户按「+0.1」歌词反而往前跑，
      // 而症状只是「看起来怪」，不会有任何报错。
      const String lrc = '[00:10.000]起唱\n';

      final delayed = LyricsParser.buildModelFromRaw(
        lrc,
        predictDuration: false,
        manualOffset: const Duration(milliseconds: 1000),
      );
      final advanced = LyricsParser.buildModelFromRaw(
        lrc,
        predictDuration: false,
        manualOffset: const Duration(milliseconds: -1000),
      );

      expect(delayed.lines.first.start, const Duration(seconds: 11));
      expect(advanced.lines.first.start, const Duration(seconds: 9));
    });

    test('首行原本在 0 时，正偏移把它推到歌词之前（不丢行）', () {
      // 实测场景：歌词首句标 0 秒，实际人声 4.2 秒 ⇒ 建议 +4200。
      // 这时首行的**标签**仍会保留在 model 里（只是时间戳变了），
      // 屏幕上是「整首歌往后挪」，而不是「第一行不见了」。
      const String lrc = '[00:00.000]第一句\n[00:05.000]第二句\n';

      final model = LyricsParser.buildModelFromRaw(
        lrc,
        predictDuration: false,
        manualOffset: const Duration(milliseconds: 4200),
      );

      expect(model.lines.length, 2);
      expect(model.lines.first.start, const Duration(milliseconds: 4200));
    });
  });
}
