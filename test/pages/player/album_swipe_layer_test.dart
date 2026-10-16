import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnmusic/pages/player/widgets/album_swipe_layer.dart';

/// 记录切歌回调，不触碰播放器服务。
///
/// 为什么不直接测 `FnPlayerService.next()`：它会顺着 `_activateIndex`
/// 真去解析音频源（`routeForSong` / `_buildAudioSource`），在 widget 测试里
/// 会挂住。要钉死的是「手势 → 哪个回调」这条契约，播放器服务那一段另有
/// 它自己的测试。
class _SwipeSpy {
  int next = 0;
  int previous = 0;
  int taps = 0;
}

/// 把 [AlbumSwipeLayer] 挂进视口。
///
/// [onLayer] 在 pumpWidget 之后用来回读 layer 本身（读跟手位移）。
Widget _host(_SwipeSpy spy) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          height: 600,
          child: AlbumSwipeLayer(
            onNext: () => spy.next++,
            onPrevious: () => spy.previous++,
            onTap: () => spy.taps++,
            child: const ColoredBox(color: Color(0xFF000000)),
          ),
        ),
      ),
    ),
  );
}

/// 读当前挂载的 State —— [AlbumSwipeLayerState.dragDx] 就是跟手位移。
AlbumSwipeLayerState _stateOf(WidgetTester tester) =>
    tester.state<AlbumSwipeLayerState>(find.byType(AlbumSwipeLayer));

void main() {
  // ---- 纯判定 ----

  group('resolveAlbumSwipe', () {
    test('手指向左滑（dx 为负）判为下一首', () {
      expect(resolveAlbumSwipe(-120, -800), AlbumSwipeAction.next);
    });

    test('手指向右滑（dx 为正）判为上一首', () {
      expect(resolveAlbumSwipe(120, 800), AlbumSwipeAction.previous);
    });

    test('位移不足阈值不切歌', () {
      expect(
        resolveAlbumSwipe(-20, 0),
        AlbumSwipeAction.none,
        reason: '轻微手抖不该切歌',
      );
    });

    test('位移不足但速度够快仍切歌（快速轻弹）', () {
      expect(
        resolveAlbumSwipe(-10, -900),
        AlbumSwipeAction.next,
        reason: '快速轻弹位移很小，只看位移会让人以为没响应',
      );
    });

    test('速度不够但位移够仍切歌（慢慢拖一大段）', () {
      expect(resolveAlbumSwipe(200, 0), AlbumSwipeAction.previous);
    });

    test('拖出去又拉回来不切歌（方向由净位移决定）', () {
      expect(resolveAlbumSwipe(0, 0), AlbumSwipeAction.none);
    });

    test('恰好等于阈值也算触发', () {
      expect(
        resolveAlbumSwipe(-kAlbumSwipeDistanceThreshold, 0),
        AlbumSwipeAction.next,
      );
    });
  });

  // ---- 手势接线 ----

  testWidgets('向左拖动触发 onNext', (WidgetTester tester) async {
    final _SwipeSpy spy = _SwipeSpy();
    await tester.pumpWidget(_host(spy));

    await tester.dragFrom(const Offset(200, 300), const Offset(-200, 0));
    await tester.pumpAndSettle();

    expect(spy.next, 1);
    expect(spy.previous, 0);
  });

  testWidgets('向右拖动触发 onPrevious', (WidgetTester tester) async {
    final _SwipeSpy spy = _SwipeSpy();
    await tester.pumpWidget(_host(spy));

    await tester.dragFrom(const Offset(200, 300), const Offset(200, 0));
    await tester.pumpAndSettle();

    expect(spy.previous, 1);
    expect(spy.next, 0);
  });

  testWidgets('小幅拖动不触发任何切歌', (WidgetTester tester) async {
    final _SwipeSpy spy = _SwipeSpy();
    await tester.pumpWidget(_host(spy));

    await tester.dragFrom(const Offset(200, 300), const Offset(-15, 0));
    await tester.pumpAndSettle();

    expect(spy.next, 0);
    expect(spy.previous, 0);
  });

  testWidgets('单击触发 onTap（点空白处进歌词页的入口）', (
    WidgetTester tester,
  ) async {
    final _SwipeSpy spy = _SwipeSpy();
    await tester.pumpWidget(_host(spy));

    await tester.tapAt(const Offset(200, 300));
    await tester.pumpAndSettle();

    expect(spy.taps, 1);
    expect(spy.next, 0);
    expect(spy.previous, 0);
  });

  testWidgets('拖动跟手：中途内容跟着手指位移', (WidgetTester tester) async {
    final _SwipeSpy spy = _SwipeSpy();
    await tester.pumpWidget(_host(spy));
    final AlbumSwipeLayerState state = _stateOf(tester);

    final TestGesture gesture = await tester.startGesture(
      const Offset(200, 300),
    );
    // 一步步移动且每步都 pump：一次性位移在手势竞技场里不足以让
    // HorizontalDrag 胜出（第一步会被竞技场吞掉），真实手指也不是这样动的。
    // 第一步 moveBy 会被手势竞技场吞掉（HorizontalDrag 要先超过 slop
    // 才开始报 delta），所以拖 5 步 -20 只累计 -80。真实手指同样如此 ——
    // 触摸起点到 slop 那一小段本来就不跟手。
    for (int i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
    }

    expect(
      state.dragDx.value,
      closeTo(-80, 0.5),
      reason: '拖动中内容要跟着手指走，否则切歌像「突然跳过去」',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('松手后位移归零（回弹），不残留偏移', (
    WidgetTester tester,
  ) async {
    final _SwipeSpy spy = _SwipeSpy();
    await tester.pumpWidget(_host(spy));
    final AlbumSwipeLayerState state = _stateOf(tester);

    final TestGesture gesture = await tester.startGesture(
      const Offset(200, 300),
    );
    for (int i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(state.dragDx.value, 0);
  });

  testWidgets('跟手位移不超过 1/3 屏宽（到底后不再跟随）', (
    WidgetTester tester,
  ) async {
    final _SwipeSpy spy = _SwipeSpy();
    await tester.pumpWidget(_host(spy));
    final AlbumSwipeLayerState state = _stateOf(tester);

    final TestGesture gesture = await tester.startGesture(
      const Offset(350, 300),
    );
    // 视口 800 宽 → 上限 800/3 ≈ 266.7；这里拖 600，期望被夹住。
    for (int i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
    }

    expect(
      state.dragDx.value,
      closeTo(-800 / 3, 0.5),
      reason: '要有「已经到底」的物理反馈，不能无限拖',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });
}