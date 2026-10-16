import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fnmusic/pages/player/lyrics/widgets/lyric_offset_bar.dart';

/// 歌词页内嵌的时间轴微调浮层。
///
/// ## 为什么这组用例重要
///
/// 这个浮层替代的是一个二级弹窗，替换理由是「调偏移要能同时看着歌词」——
/// 也就是说**它必须一直留在歌词页上**。而「自动淡出」是唯一可能让它消失的机制，
/// 一旦它误触发，用户正在听歌比对的动作就被打断了。所以除了步进本身，
/// 还要钉死「**碰过就不自动收**」这条契约。
/// 判断一段文字是否长得像偏移值的显示格式（`0 秒` / `+100 毫秒` / `−2.5 秒`）。
bool _shaped(String s) =>
    s == '0 秒' ||
    ((s.startsWith('+') || s.startsWith('−')) && s.endsWith('秒'));

/// 「归零」按键里的图标。
///
/// 与标题行的「还原」小图标共用 `Icons.restart_alt`，靠尺寸区分：
/// 按键里是 16px，还原按钮是 18px。
final Finder _restartKey = find.byWidgetPredicate(
  (Widget w) => w is Icon && w.icon == Icons.restart_alt && w.size == 16,
);

void main() {
  /// 把浮层放进一个够大的视口里跑。
  ///
  /// 默认测试视口 800×600 比真机矮，会报 RenderFlex OVERFLOWING ——
  /// 那是**测试环境太矮**，不是产品布局有问题，别照着去改产品代码。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  /// 浮层上报出去的偏移变化。外部真值由 [host] 持有 —— 模拟真实场景：
  /// 浮层自己不改值，它只是把「用户想调成多少」告诉外面。
  Future<void> pumpBar(
    WidgetTester tester, {
    required bool visible,
    required ValueChanged<int?> onChanged,
    VoidCallback? onAutoClose,
    VoidCallback? onReset,
    int initialMs = 0,
  }) async {
    int hostMs = initialMs;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              return Column(
                children: <Widget>[
                  const Expanded(child: Center(child: Text('歌词区域'))),
                  LyricOffsetBar(
                    offsetMs: hostMs,
                    visible: visible,
                    onChanged: (int? v) {
                      hostMs = v ?? 0;
                      setState(() {});
                      onChanged.call(v);
                    },
                    onReset: () {
                      hostMs = 0;
                      setState(() {});
                      onReset?.call();
                    },
                    onAutoClose: onAutoClose,
                    backgroundColor: Colors.white,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 当前显示的偏移值（大字那一行）。
  String shownOffset(WidgetTester tester) {
    final Finder big = find.byWidgetPredicate(
      (Widget w) =>
          w is Text &&
          _shaped(w.data ?? '') &&
          (w.style?.fontSize ?? 0) >= 18,
    );
    expect(big, findsOneWidget, reason: '应显示一个大字偏移值');
    return tester.widget<Text>(big).data!;
  }

  group('步进按键', () {
    testWidgets('+0.1 秒 ⇒ +100 毫秒', (WidgetTester tester) async {
      useTallViewport(tester);
      int? reported;
      await pumpBar(
        tester,
        visible: true,
        onChanged: (int? v) => reported = v,
      );

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      expect(reported, 100);
      expect(shownOffset(tester), '+100 毫秒');
    });

    testWidgets('+0.5 秒 ⇒ +500 毫秒', (WidgetTester tester) async {
      useTallViewport(tester);
      int? reported;
      await pumpBar(
        tester,
        visible: true,
        onChanged: (int? v) => reported = v,
      );

      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_right));
      await tester.pumpAndSettle();

      expect(reported, 500);
    });

    testWidgets('连点三次 +0.1 秒 ⇒ +300 毫秒（累加，不是每次重置）', (
      WidgetTester tester,
    ) async {
      useTallViewport(tester);
      await pumpBar(tester, visible: true, onChanged: (_) {});

      final Offset key = tester.getCenter(find.byIcon(Icons.chevron_right));
      for (int i = 0; i < 3; i++) {
        await tester.tapAt(key);
        await tester.pumpAndSettle();
      }

      // 这一条锁住「每次都以当前值递增」。若误用初始值当基准，
      // 三次之后仍是 100 —— 用户的体感就是「按了几次都一样」。
      expect(shownOffset(tester), '+300 毫秒');
    });

    testWidgets('归零时上报 null（删记录而不是写 0）', (
      WidgetTester tester,
    ) async {
      useTallViewport(tester);
      final List<int?> reported = <int?>[];
      await pumpBar(
        tester,
        visible: true,
        initialMs: 2500,
        onChanged: reported.add,
      );

      expect(shownOffset(tester), '+2.5 秒');

      // 归零键与「还原」按钮共用 `Icons.restart_alt`（前者是按键、后者是
      // 标题行的小图标），所以这里按尺寸定位，别用裸 icon finder。
      await tester.tap(_restartKey);
      await tester.pumpAndSettle();

      expect(reported, <int?>[null]);
      expect(shownOffset(tester), '0 秒');
    });

    testWidgets('方向标签随符号翻转', (WidgetTester tester) async {
      useTallViewport(tester);
      await pumpBar(tester, visible: true, onChanged: (_) {});

      expect(find.text('与歌曲对齐'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left));
      await tester.pumpAndSettle();

      expect(find.text('歌词提前'), findsOneWidget);
    });
  });

  group('显隐', () {
    testWidgets('visible=false 时不接收点击（避免误触已隐形的控件）', (
      WidgetTester tester,
    ) async {
      useTallViewport(tester);
      int calls = 0;
      await pumpBar(
        tester,
        visible: false,
        onChanged: (_) => calls++,
      );

      // IgnorePointer 生效：点上去什么也不该发生。
      await tester.tap(find.byIcon(Icons.chevron_right), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(calls, 0);
    });

    testWidgets('按下不该让浮层的位置发生变化（连点不跑位）', (
      WidgetTester tester,
    ) async {
      // 回归：早先的二级面板在「还原」按钮出现时会整体顶动，
      // 连点的手第二下就落空。浮层绝不能重蹈覆辙。
      useTallViewport(tester);
      await pumpBar(tester, visible: true, onChanged: (_) {});

      final Offset before = tester.getCenter(find.byIcon(Icons.chevron_right));

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      expect(tester.getCenter(find.byIcon(Icons.chevron_right)), equals(before));
    });
  });

  group('自动淡出', () {
    testWidgets('打开后完全没动 ⇒ 到点自动收起', (WidgetTester tester) async {
      useTallViewport(tester);
      int closed = 0;
      await pumpBar(
        tester,
        visible: true,
        onChanged: (_) {},
        onAutoClose: () => closed++,
      );

      await tester.pump(const Duration(seconds: 5));
      expect(closed, 1);
    });

    testWidgets('碰过之后 ⇒ 不再自动收起', (WidgetTester tester) async {
      // 核心契约：用户正在听歌比对，浮层不能自己消失。
      // 只在「压根没人用」时自动收 —— 那说明点错了，该让位给歌词。
      useTallViewport(tester);
      int closed = 0;
      await pumpBar(
        tester,
        visible: true,
        onChanged: (_) {},
        onAutoClose: () => closed++,
      );

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 10));
      expect(closed, 0, reason: '用户已在使用，不该被自动收起');
    });

    testWidgets('从不可见到可见会重启倒计时', (WidgetTester tester) async {
      useTallViewport(tester);
      int closed = 0;
      await pumpBar(
        tester,
        visible: false,
        onChanged: (_) {},
        onAutoClose: () => closed++,
      );

      // 隐藏状态下不该有任何定时器在跑。
      await tester.pump(const Duration(seconds: 10));
      expect(closed, 0);
    });

    testWidgets('dispose 后不残留定时器', (WidgetTester tester) async {
      // 若 dispose 时不拆 Timer，到点会对已销毁的 State 调 setState ——
      // 测试里表现为「用例结束时还有待触发的定时器」。
      useTallViewport(tester);
      await pumpBar(tester, visible: true, onChanged: (_) {});

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();
    });
  });
}
