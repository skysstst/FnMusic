import 'package:flutter/material.dart';

/// 封面页横向拖动产生的动作。
enum AlbumSwipeAction {
  /// 没到阈值：什么都不做（回弹）。
  none,

  /// 手指向左滑 —— 下一首。
  next,

  /// 手指向右滑 —— 上一首。
  previous,
}

/// 判定一次横向拖动该不该切歌、以及往哪边切。
///
/// 抽成顶层纯函数而不是写在 `GestureDetector` 回调里，是因为它是这套交互里
/// **唯一带业务判断**的部分（阈值、方向、快速轻弹），而拖动手势本身在
/// widget 测试里要真跑一遍才能验证。把判断和手势分开，就能对判断做纯单测。
///
/// ## 阈值为什么要两个
///
/// 只看位移：「慢慢拖一大段」判不出；只看速度：「慢慢挪一点点」又像坏了。
/// 两者取或，两种用法都成立。
const double kAlbumSwipeDistanceThreshold = 60;
const double kAlbumSwipeVelocityThreshold = 320;

/// 核心判定。
///
/// [dx] 是拖动累计位移（向右为正），[velocity] 是松手时的横向速度
/// （向右为正）。方向**以二者之和**判断，这样「快速轻弹」即使位移不足
/// 阈值也能触发，而「拖出去一段又拉回来」不会误切。
AlbumSwipeAction resolveAlbumSwipe(double dx, double velocity) {
  final bool passDistance = dx.abs() >= kAlbumSwipeDistanceThreshold;
  final bool passVelocity = velocity.abs() >= kAlbumSwipeVelocityThreshold;
  if (!passDistance && !passVelocity) return AlbumSwipeAction.none;
  // 手指向左（负）= 下一首；向右（正）= 上一首。
  return dx + velocity < 0 ? AlbumSwipeAction.next : AlbumSwipeAction.previous;
}

/// 封面页的手势层：横向拖动切歌 + 跟手位移 + 单击进歌词页。
///
/// ## 为什么单独抽成部件
///
/// 这三件事（跟手位移、阈值判定、切歌）是一体的，但它们**都不该和播放器服务
/// 耦合**：切歌动作以回调抛出去，部件本身只管手势。于是可以在 widget 测试里
/// 用一个计数器接住回调，把「手指向左滑确实产出 next」这类契约钉死，而不必
/// 真的去解析音频源。
///
/// ## 为什么只盖封面页
///
/// 歌词页有自己的竖向拖动（拖拽歌词调进度）和底部控件，横滑在这里没有语义，
/// 所以手势层只包封面页布局，不包整页。
class AlbumSwipeLayer extends StatefulWidget {
  /// 手指向左滑 → 下一首。
  final VoidCallback onNext;

  /// 手指向右滑 → 上一首。
  final VoidCallback onPrevious;

  /// 单击封面页（歌词预览、底栏迷你歌词之外的区域）。
  final VoidCallback? onTap;

  final Widget child;

  const AlbumSwipeLayer({
    super.key,
    required this.onNext,
    required this.onPrevious,
    this.onTap,
    required this.child,
  });

  @override
  AlbumSwipeLayerState createState() => AlbumSwipeLayerState();
}

/// [AlbumSwipeLayer] 的 State。
///
/// 刻意公开（而不是常规的私有 State）—— 测试要读 [dragDx] 来验证
/// 「拖动中内容跟手」。私有 State 在测试文件里拿不到类型；退一步用
/// GlobalKey 也不行：字段形式的 GlobalKey 不是 widget 的 `key`，
/// `currentState` 永远是 null（这个坑踩过一次）。
class AlbumSwipeLayerState extends State<AlbumSwipeLayer> {
  /// 跟手位移。挂成 [ValueNotifier] 而不是普通字段 + `setState`：
  /// 拖动过程是高频变更，走 setState 会把整棵子树每帧重建。
  final ValueNotifier<double> dragDx = ValueNotifier<double>(0);

  /// 跟手位移上限 = 1/3 屏宽。超过就不再跟随，给出「已经到底」的物理反馈。
  double get _maxDx => MediaQuery.sizeOf(context).width / 3;

  @override
  void dispose() {
    dragDx.dispose();
    super.dispose();
  }

  void _onStart(DragStartDetails details) {
    dragDx.value = 0;
  }

  void _onUpdate(DragUpdateDetails details) {
    dragDx.value =
        (dragDx.value + details.delta.dx).clamp(-_maxDx, _maxDx).toDouble();
  }

  void _onEnd(DragEndDetails details) {
    final double dx = dragDx.value;
    dragDx.value = 0;
    switch (resolveAlbumSwipe(dx, details.primaryVelocity ?? 0)) {
      case AlbumSwipeAction.next:
        widget.onNext();
      case AlbumSwipeAction.previous:
        widget.onPrevious();
      case AlbumSwipeAction.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final double maxDx = _maxDx;
    return GestureDetector(
      // opaque：空白处也要命中，否则「单击空白处进歌词页」在纯背景点不动。
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onHorizontalDragStart: _onStart,
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      child: AnimatedBuilder(
        animation: dragDx,
        builder: (context, child) {
          final double dx = dragDx.value;
          return Transform.translate(
            offset: Offset(dx, 0),
            // 边拖边淡：切换的那一下有明确的「正在翻」感，而不是内容僵着突然换掉。
            child: Opacity(
              opacity: (1 - dx.abs() / maxDx * 0.28).clamp(0.0, 1.0),
              child: child,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}
