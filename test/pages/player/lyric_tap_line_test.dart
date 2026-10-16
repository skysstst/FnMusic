import 'package:flutter/material.dart';
import 'package:flutter_lyric/core/lyric_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fnmusic/app/services/lyrics/lyrics_service.dart';
import 'package:fnmusic/pages/player/lyrics/lyric_view.dart';

/// 一份三行 LRC。
///
/// 点歌词回调会拿广播数据（行索引）去 `lines[index].start` 取时间点，
/// 没有歌词行的话这里会越界 —— 所以测试必须先给控制器喂一份词。
const String _lrc = '[00:00.00]第一行\n'
    '[00:10.00]第二行\n'
    '[00:20.00]第三行\n';

/// 挂一个歌词页。
///
/// 视口给足：默认 800×600 比真机矮，会报 RenderFlex OVERFLOWING ——
/// 那是**测试环境太矮**，不是产品布局有问题，别照着去改产品代码。
Future<void> _pumpLyrics(
  WidgetTester tester, {
  VoidCallback? onTapLine,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlayerLyricsView(showControls: false, onTapLine: onTapLine),
      ),
    ),
  );
  await tester.pump();
}

/// 模拟「用户点了第 [index] 行歌词」，返回那一行的时间点。
///
/// 走 [LyricController.notifyEvent] 广播事件，而不是去调回调：
/// `_onTapLineCallback` 是私有的外部拿不到，而广播事件正是插件内部的触发方式。
Duration? fireTapLine(int index) {
  Duration? seen;
  final LyricController controller = LyricsService.instance.controller;
  final VoidCallback unregister = controller.registerEvent(
    LyricEvent.tapLine,
    (Object? data) {
      seen = controller.lyricNotifier.value!.lines[data as int].start;
    },
  );
  controller.notifyEvent(LyricEvent.tapLine, index);
  unregister();
  return seen;
}

void main() {
  setUp(() {
    // LyricsService 单例初始化时会读 SharedPreferences（歌词视图设置），
    // 这里必须给 mock 值，否则异步初始化会在用例跑完之后才炸。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final LyricController controller = LyricsService.instance.controller;
    // 控制器是全局单例：既要把上一个用例留下的点歌词回调摘掉，
    // 也要重置歌词，否则行索引会落在旧的（更长的）模型上。
    controller.cancelOnTapLineCallback();
    controller.loadLyric(_lrc);
  });

  tearDown(() {
    LyricsService.instance.controller.cancelOnTapLineCallback();
  });

  testWidgets('传了 onTapLine：点歌词调外层回调', (WidgetTester tester) async {
    int taps = 0;
    await _pumpLyrics(tester, onTapLine: () => taps++);

    expect(taps, 0, reason: '还没点');

    final Duration? seen = fireTapLine(1);
    expect(seen, const Duration(seconds: 10));
    expect(taps, 1);

    fireTapLine(2);
    expect(taps, 2, reason: '注册不是一次性的，每点一次都该响应');
  });

  testWidgets('没传 onTapLine：不在全局控制器上留回调', (
    WidgetTester tester,
  ) async {
    await _pumpLyrics(tester);

    // 没注册任何监听者时，广播不应报错 —— 说明确实没人挂上去。
    final LyricController controller = LyricsService.instance.controller;
    expect(() => controller.notifyEvent(LyricEvent.tapLine, 0), returnsNormally);
  });

  testWidgets('改 onTapLine 后重新注册，不叠加旧回调', (
    WidgetTester tester,
  ) async {
    int a = 0;
    int b = 0;

    await _pumpLyrics(tester, onTapLine: () => a++);
    // 同一个 State 里换回调：didUpdateWidget 必须重注册。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerLyricsView(showControls: false, onTapLine: () => b++),
        ),
      ),
    );
    await tester.pump();

    fireTapLine(0);
    expect(
      a,
      0,
      reason: '旧的回调必须已被注销，否则一次点击会触发两处',
    );
    expect(b, 1);
  });
}