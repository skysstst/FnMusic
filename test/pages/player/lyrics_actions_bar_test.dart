import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals/signals.dart';

import 'package:fnmusic/pages/player/lyrics/widgets/lyrics_actions_bar.dart';

/// 记录重建次数的「歌词区」替身。
///
/// 用一个**带身份的** widget 而不是纯 `Text`：纯文本在重建后看不出区别，
/// 而这里要断言的恰恰是「它没有被重建」，所以必须能观测到 element/state 的身份。
class _CountingLyricsController {
  int builds = 0;
}

/// 歌词区替身。`_CountingLyricsState` 的身份是否不变，是本组断言的核心。
class _CountingLyrics extends StatefulWidget {
  const _CountingLyrics({super.key, required this.counter});

  final _CountingLyricsController counter;

  @override
  State<_CountingLyrics> createState() => _CountingLyricsState();
}

class _CountingLyricsState extends State<_CountingLyrics> {
  @override
  Widget build(BuildContext context) {
    widget.counter.builds++;
    return const Center(child: Text('歌词区域'));
  }
}

/// 「时」徽标的重建隔离。
///
/// ## 为什么这条测试存在
///
/// 用户反馈过一个观感问题：点「时」展开微调浮层时，**整页歌词都跟着跳一下**。
/// 根因不是动画写错了，而是切换浮层时用了 `setState` —— 它重建整个歌词页，
/// 正在滚动的歌词列表随之重排。
///
/// 修法是把订阅关系收进徽标自己（`Watch`），但这种「优化」特别容易在以后
/// 被人顺手改回 `setState` 而无声退化：功能全对、测试全绿，只有肉眼能看出跳动。
/// 所以这里直接把「歌词列表的 element 必须保持同一个」钉成断言。
void main() {
  testWidgets('切浮层时操作栏里其余部件不重建', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 被当作「歌词区」替身的关键部件：它带身份，重建了就换一个 element。
    final GlobalKey<_CountingLyricsState> lyricsKey =
        GlobalKey<_CountingLyricsState>();
    final _CountingLyricsController counter = _CountingLyricsController();

    final Signal<bool> open = signal(false);
    addTearDown(open.dispose);

    Widget buildLyrics() => _CountingLyrics(key: lyricsKey, counter: counter);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              Expanded(child: buildLyrics()),
              LyricsActionsBar(
                hasTranslation: false,
                showTranslation: false,
                onOpenSettings: () {},
                onToggleTranslation: () {},
                offsetBar: OffsetBadgeSignal(
                  open: open,
                  onTap: () => open.value = !open.value,
                  adjusted: false,
                  color: Colors.black,
                ),
                color: Colors.black,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final _CountingLyricsState lyricsBefore = lyricsKey.currentState!;
    final int buildsBefore = counter.builds;

    // 展开浮层。
    open.value = true;
    await tester.pumpAndSettle();

    expect(open.value, isTrue);
    expect(
      counter.builds,
      buildsBefore,
      reason: '歌词区域不该因为浮层开合而重建 —— 这正是用户报告的跳动',
    );
    expect(
      identical(lyricsKey.currentState, lyricsBefore),
      isTrue,
      reason: '歌词区域的 State 必须还是同一个对象',
    );

    // 收起浮层，同样不应牵动歌词。
    open.value = false;
    await tester.pumpAndSettle();

    expect(counter.builds, buildsBefore);
    expect(identical(lyricsKey.currentState, lyricsBefore), isTrue);
  });

  testWidgets('「时」徽标自身会跟随开合状态更新外观', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final Signal<bool> open = signal(false);
    addTearDown(open.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricsActionsBar(
            hasTranslation: false,
            showTranslation: false,
            onOpenSettings: () {},
            onToggleTranslation: () {},
            offsetBar: OffsetBadgeSignal(
              open: open,
              onTap: () => open.value = !open.value,
              adjusted: false,
              color: Colors.black,
            ),
            color: Colors.black,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 「时」徽标是两层 Container（外层只做点击区，内层才有 decoration），
    // 所以要按「decoration 是 BoxDecoration」筛选，不能直接取 `.last`。
    Color fillOf() {
      final Finder ancestors = find.ancestor(
        of: find.text('时'),
        matching: find.byType(Container),
      );
      final BoxDecoration deco = tester
          .widgetList<Container>(ancestors)
          .firstWhere((Container c) => c.decoration is BoxDecoration)
          .decoration! as BoxDecoration;
      return deco.color!;
    }

    expect(fillOf(), Colors.transparent);

    open.value = true;
    await tester.pumpAndSettle();

    // 打开态：填充主色 —— 用户据此判断「再点一下会收起」。
    expect(fillOf(), Colors.black);
  });

  testWidgets('adjusted 与 open 是两个独立状态', (WidgetTester tester) async {
    // 拆开的原因：adjusted 是**历史**（我调过它），open 是**开关**（控件正开着）。
    // 混成一个视觉会让人不敢点第二次。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final Signal<bool> open = signal(false);
    addTearDown(open.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricsActionsBar(
            hasTranslation: false,
            showTranslation: false,
            onOpenSettings: () {},
            onToggleTranslation: () {},
            offsetBar: OffsetBadgeSignal(
              open: open,
              onTap: () {},
              adjusted: true, // 调过偏移，但浮层此刻关着
              color: Colors.black,
            ),
            color: Colors.black,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder ancestors = find.ancestor(
      of: find.text('时'),
      matching: find.byType(Container),
    );
    final BoxDecoration deco = tester
        .widgetList<Container>(ancestors)
        .firstWhere((Container c) => c.decoration is BoxDecoration)
        .decoration! as BoxDecoration;

    // 没填充（因为浮层关着）⇒ 不管 adjusted 是什么。
    expect(deco.color, Colors.transparent);

    final Text label = tester.widget<Text>(find.text('时'));
    expect(
      label.style?.fontWeight,
      FontWeight.w900,
      reason: 'adjusted 仍然通过加粗体现',
    );
  });
}
