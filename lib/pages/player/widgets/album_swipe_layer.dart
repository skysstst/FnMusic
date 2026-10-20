import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/state/song_state.dart';

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

/// 封面轮播手势层：横向拖动切歌（网易云式交互）。
///
/// ## 交互模型
///
/// - **跟手**：封面随手指 1:1 移动（夹紧在 ±舞台边长内），相邻封面从
///   对应方向露头 —— 三槽轮播，不是「滑一下整页跳走」。
/// - **方向分离**：左滑 = 下一首（封面向左滑出），右滑 = 上一首（向右
///   滑出）。提交后沿**滑动方向**继续滑出，新封面从另一侧滑入 ——
///   一镜到底的传送带效果。
/// - **手停即停**：拖动期间没有惯性，手指停内容就停。
/// - **可打断**：回弹动画进行中再次触摸，从当前位移接管，可以继续拖。
///   （提交吸附只有 ~300ms 且不可逆，不打断。）
/// - **提交判定**：位移 ≥60px 或速度 ≥320px/s 即提交；目标方向
///   [nextCover] / [previousCover] 为 null（队列到头等）时回弹不切。
///
/// ## 为什么封面是「部件」而不是「歌曲」
///
/// 提交动画期间旧封面必须保持**提交那一刻的画面**。歌曲切换是异步的
/// （音频源解析完成后 song 信号才更新，可能数百毫秒），活部件会跟着
/// 变成新歌。所以调用方传入的是用显式歌曲构建的**纯部件**（不读全局
/// 信号），层在提交时捕获三份部件，动画期间用捕获值渲染；动画结束后
/// 若歌曲还没切过来（[currentSong] 没变），保持吸附态等它，切过来的
/// 那一帧再无缝切回活部件 —— 全程不跳变。
class AlbumSwipeLayer extends StatefulWidget {
  /// 手指向左滑 → 下一首。
  final VoidCallback onNext;

  /// 手指向右滑 → 上一首。
  final VoidCallback onPrevious;

  /// 单击封面页（进歌词页的入口）。
  final VoidCallback? onTap;

  /// 当前封面（活部件，随歌曲变化）。
  final Widget currentCover;

  /// 下一首封面；null = 不能切下一首（手势回弹）。
  final Widget? nextCover;

  /// 上一首封面；null = 不能切上一首（手势回弹）。
  final Widget? previousCover;

  /// 当前歌曲（显式值）。
  ///
  /// 只用于「吸附结束但歌曲信号尚未更新」的等待判定：歌曲信号在音频源
  /// 解析完成后才更新（见 `FnPlayerService._activateIndex` 末尾的
  /// `_emitSnapshot`），若不等它，轮播会在动画结束时跳回旧歌、歌曲
  /// 就位后再跳到新歌。按引用比较（signal 只在换歌时换实例）。
  final SongEntity? currentSong;

  const AlbumSwipeLayer({
    super.key,
    required this.onNext,
    required this.onPrevious,
    this.onTap,
    required this.currentCover,
    this.nextCover,
    this.previousCover,
    this.currentSong,
  });

  @override
  AlbumSwipeLayerState createState() => AlbumSwipeLayerState();
}

/// [AlbumSwipeLayer] 的 State。
///
/// 刻意公开（而不是常规的私有 State）—— 测试要读 [offset] 来验证
/// 「拖动中内容跟手」。私有 State 在测试文件里拿不到类型；退一步用
/// GlobalKey 也不行：字段形式的 GlobalKey 不是 widget 的 `key`，
/// `currentState` 永远是 null（这个坑踩过一次）。
class AlbumSwipeLayerState extends State<AlbumSwipeLayer>
    with SingleTickerProviderStateMixin {
  /// 当前平移量（舞台坐标，0 = 当前封面居中）。
  ///
  /// 挂成 [ValueNotifier] 而不是普通字段 + `setState`：拖动与动画都是
  /// 高频变更，走 setState 会把整棵子树每帧重建。
  final ValueNotifier<double> offset = ValueNotifier<double>(0);

  /// 补间动画控制器：驱动回弹与提交吸附。
  late final AnimationController _anim;

  double _animFrom = 0;
  double _animTo = 0;

  /// 已提交（切歌吸附态）：用提交时捕获的三份封面渲染。
  ///
  /// 从提交一直保持到歌曲信号切过来（或兜底超时）—— 期间活部件可能
  /// 还是旧歌，不能用。
  bool _settled = false;
  Widget? _settleCurrent;
  Widget? _settleNext;
  Widget? _settlePrev;
  SongEntity? _settleSong;

  /// 兜底定时器：歌曲 2 秒还没切过来（切歌失败等异常），放弃等待、
  /// 回到活部件，避免轮播卡死。
  Timer? _settleTimeout;

  /// 舞台边长（正方形 = 可用区域最短边）。LayoutBuilder 实测。
  double _side = 0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this);
    _anim.addListener(_onAnimTick);
    _anim.addStatusListener(_onAnimStatus);
  }

  @override
  void dispose() {
    _settleTimeout?.cancel();
    _anim.removeListener(_onAnimTick);
    _anim.removeStatusListener(_onAnimStatus);
    _anim.dispose();
    offset.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AlbumSwipeLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 吸附态等待歌曲切过来：信号更新（新实例）即无缝归位。
    if (_settled && !identical(widget.currentSong, _settleSong)) {
      _finishSettle();
    }
  }

  void _onAnimTick() {
    final double t = Curves.easeOutCubic.transform(_anim.value);
    offset.value = _animFrom + (_animTo - _animFrom) * t;
  }

  void _onAnimStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!_settled) return;
    // 吸附动画结束：歌曲可能还没切过来（音频源解析是异步的）。
    // 已切 → 立即归位；没切 → 保持吸附态等 didUpdateWidget。
    if (!identical(widget.currentSong, _settleSong)) {
      _finishSettle();
    } else {
      _settleTimeout?.cancel();
      _settleTimeout = Timer(const Duration(seconds: 2), () {
        if (_settled) _finishSettle();
      });
    }
  }

  /// 结束吸附态：切回活部件并归位。
  ///
  /// 活部件的「当前封面」就是刚才滑到中间的那张（同一首歌），同位同图，
  /// 视觉无缝。
  void _finishSettle() {
    _settleTimeout?.cancel();
    _settleTimeout = null;
    _settled = false;
    _settleCurrent = null;
    _settleNext = null;
    _settlePrev = null;
    _settleSong = null;
    offset.value = 0;
  }

  // ---------- 手势 ----------

  void _onStart(DragStartDetails details) {
    if (_settled) return; // 提交吸附不可打断（几百毫秒，且已切歌）
    if (_anim.isAnimating) {
      // 打断回弹：冻结在当前位移，拖动从这里接管。
      _anim.stop();
    }
  }

  void _onUpdate(DragUpdateDetails details) {
    if (_settled) return;
    offset.value = (offset.value + details.delta.dx)
        .clamp(-_side, _side)
        .toDouble();
  }

  void _onEnd(DragEndDetails details) {
    if (_settled) return;
    final double dx = offset.value;
    final AlbumSwipeAction action = resolveAlbumSwipe(
      dx,
      details.primaryVelocity ?? 0,
    );
    switch (action) {
      case AlbumSwipeAction.next when widget.nextCover != null:
        _commit(-1);
      case AlbumSwipeAction.previous when widget.previousCover != null:
        _commit(1);
      case AlbumSwipeAction.none:
      case AlbumSwipeAction.next:
      case AlbumSwipeAction.previous:
        _springBack();
    }
  }

  /// 提交切歌：捕获三份封面 → 触发回调 → 沿滑动方向吸附到边。
  void _commit(int dir) {
    _settled = true;
    _settleCurrent = widget.currentCover;
    _settleNext = widget.nextCover;
    _settlePrev = widget.previousCover;
    _settleSong = widget.currentSong;
    // 先捕获再回调：回调会启动切歌（异步），活部件随后变成新歌，
    // 但吸附期间用的是捕获值，画面连续。
    if (dir < 0) {
      widget.onNext();
    } else {
      widget.onPrevious();
    }
    _animateTo(dir * _side);
  }

  void _springBack() {
    _animateTo(0);
  }

  void _animateTo(double target) {
    _animFrom = offset.value;
    _animTo = target;
    // 距离越远动画略长，封顶 320ms，避免慢拖时拖沓。
    final double distance = (_animTo - _animFrom).abs();
    final int ms = _side <= 0
        ? 260
        : (180 + distance / _side * 140).clamp(180, 320).round();
    _anim.duration = Duration(milliseconds: ms);
    _anim.forward(from: 0);
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _side = constraints.biggest.shortestSide;
        return GestureDetector(
          // opaque：封面四周留白也要能点（单击进歌词页）。
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onHorizontalDragStart: _onStart,
          onHorizontalDragUpdate: _onUpdate,
          onHorizontalDragEnd: _onEnd,
          child: Center(
            child: ClipRect(
              // 轮播视口 = 正方形舞台；封面滑出时在边缘裁掉。
              child: SizedBox(
                width: _side,
                height: _side,
                child: AnimatedBuilder(
                  animation: Listenable.merge(<Listenable>[offset, _anim]),
                  builder: (BuildContext context, Widget? child) {
                    return _buildCarousel();
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCarousel() {
    final Widget current = _settled ? _settleCurrent! : widget.currentCover;
    final Widget? next = _settled ? _settleNext : widget.nextCover;
    final Widget? prev = _settled ? _settlePrev : widget.previousCover;
    return Transform.translate(
      // 主槽是 Row 的第二个孩子（Row 内偏移 _side），
      // 平移量 = offset - _side 让主槽对准 offset。
      offset: Offset(offset.value - _side, 0),
      child: OverflowBox(
        // 三槽轮播总宽 3×side，必然超出正方形视口：用 OverflowBox
        // 放开宽度约束（否则 RenderFlex 报溢出），超出部分由外层
        // ClipRect 裁掉 —— 封面滑出时在舞台边缘消失。
        alignment: Alignment.centerLeft,
        minWidth: 0,
        maxWidth: double.infinity,
        child: Row(
          children: <Widget>[
            SizedBox(width: _side, height: _side, child: prev),
            SizedBox(width: _side, height: _side, child: current),
            SizedBox(width: _side, height: _side, child: next),
          ],
        ),
      ),
    );
  }
}
