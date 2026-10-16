import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../app/services/lyrics/lyric_offset_store.dart';

/// 歌词页内嵌的时间轴微调浮层。
///
/// ## 为什么不再是二级面板
///
/// 早先它是 `showModalBottomSheet` 弹出来的**二级页面**，用户指出这是设计错误：
/// 调偏移的本质是「**看着歌词、听着歌，来回比对**」，而底部弹起的面板把整个歌词页
/// 盖住了 —— 于是变成「调一下 → 关闭 → 返回去看进度对不对 → 再进来调」。
/// 一次调整要开合三四次，效率极低。
///
/// 真正的形态应该是**浮在歌词之上的一个小控件**：歌词全程可见，边听边调，
/// 调完点一下「时」就消失，什么都不挡。
///
/// ## 交互契约
///
/// - 点「时」⇒ 淡入；再点「时」⇒ 淡出。
/// - 浮层开着的时候**不**自动消失 —— 用户正在听歌比对，中途消失等于打断他。
///   自动淡出只发生在「打开后压根没动过」的情况（见 `_autoCloseTimer`）：
///   那说明用户点错了，不该留个东西在屏幕上挡歌词。
/// - 拖滑杆 / 点步进键 ⇒ 重置自动淡出倒计时（如果开着的话）。
///
/// 也就是说：**用了就留着，没用就自己走**。
class LyricOffsetBar extends StatefulWidget {
  /// 当前偏移（毫秒）。由外部从 `LyricsService.currentOffsetSignal` 读入。
  final int offsetMs;

  /// 是否显示。
  final bool visible;

  /// 偏移变化时回调（已钳制，可直接写回）。`null` 表示打回基准。
  final ValueChanged<int?> onChanged;

  /// 点「还原」：撤销这首歌的手动偏移。
  final VoidCallback onReset;

  /// 「打开后一直没人动」的自动淡出回调。可为 null（不自动淡出）。
  ///
  /// 只在用户**没碰过**时触发：任何一次拖动或按步进都会取消倒计时。
  final VoidCallback? onAutoClose;

  /// 歌词区背景色，用于给浮层挑一个不刺眼又看得清的底色。
  final Color backgroundColor;

  const LyricOffsetBar({
    super.key,
    required this.offsetMs,
    required this.visible,
    required this.onChanged,
    required this.onReset,
    required this.backgroundColor,
    this.onAutoClose,
  });

  @override
  State<LyricOffsetBar> createState() => _LyricOffsetBarState();
}

class _LyricOffsetBarState extends State<LyricOffsetBar> {
  /// 滑杆的半量程（毫秒）。
  ///
  /// 刻意**不等于** [LyricOffsetStore.maxAbsMs]（±10 分钟）：歌词时间轴差一分
  /// 钟以上不是「没对齐」而是「配错版本」，那种该去「歌词来源」重配。更关键的是
  /// 分辨率 —— 这个浮层宽度有限，摊到 20 秒时每 100ms 有几个像素（能拖得动），
  /// 摊到 1200 秒则是 0.0003px，数学上就拖不准了。
  static const int _sliderSpanMs = 10000;

  /// 「打开后完全没动过」就自动淡出的时长。
  static const Duration _idleAutoClose = Duration(seconds: 4);

  Timer? _autoCloseTimer;

  /// 滑杆拖动时的临时值。只在拖动期间偏离 `widget.offsetMs`，松手才提交。
  int? _dragMs;

  int get _shownMs => _dragMs ?? widget.offsetMs;

  bool get _adjusted => _shownMs != 0;

  @override
  void initState() {
    super.initState();
    _syncAutoClose();
  }

  @override
  void didUpdateWidget(covariant LyricOffsetBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切歌后偏移值可能从外部变了，拖动中的临时值必须丢掉，否则会一直显示旧值。
    if (widget.offsetMs != oldWidget.offsetMs) _dragMs = null;
    if (widget.visible != oldWidget.visible) _syncAutoClose();
  }

  @override
  void dispose() {
    // 必须拆：挂着的 Timer 会在浮层已被移除后触发 `setState`，那就是对已销毁
    // 状态对象的写入，测试里表现为「用例结束时还有待触发定时器」。
    _autoCloseTimer?.cancel();
    super.dispose();
  }

  /// 显示变化时重启倒计时；隐藏时立刻拆掉。
  void _syncAutoClose() {
    _autoCloseTimer?.cancel();
    _autoCloseTimer = null;
    if (!widget.visible) return;
    _autoCloseTimer = Timer(_idleAutoClose, () {
      if (!mounted) return;
      // 只在「用户没碰过」时自动收：任何一次按下都会先调 `_touch()` 把 timer 拆掉。
      widget.onAutoClose?.call();
    });
  }

  /// 用户有任何操作：重置自动淡出倒计时，并把这个浮层标记成「有人在用」。
  void _touch() {
    if (_autoCloseTimer != null) {
      _autoCloseTimer!.cancel();
      _autoCloseTimer = null;
    }
  }

  void _set(int value, {bool commit = false}) {
    final int clamped = LyricOffsetStore.clampMs(value);
    if (commit) {
      setState(() => _dragMs = null);
      widget.onChanged(clamped == 0 ? null : clamped);
    } else {
      setState(() => _dragMs = clamped);
    }
  }

  /// 步进：以 [_shownMs]（拖动优先）为基准加增量。
  ///
  /// 刻意不用已提交值：滑杆正被拖着时同时按步进，若以已提交值为基准会跳回
  /// 老位置，手感上像是「按键失灵」。
  void _nudge(int deltaMs) {
    HapticFeedback.selectionClick();
    _touch();
    _set(_shownMs + deltaMs, commit: true);
  }

  @override
  Widget build(BuildContext context) {
    final int shown = _shownMs;
    final ThemeData theme = Theme.of(context);
    final bool isLight = theme.brightness == Brightness.light;
    final Color fg = isLight ? const Color(0xFF1A1A1A) : Colors.white;

    return AnimatedSlide(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      // 藏在歌词下方一点，而不是直接盖在歌词正中 —— 位置靠下也对应它在
      // 视觉上的层级：它是辅助工具，歌词才是主角。
      offset: widget.visible ? Offset.zero : const Offset(0, 0.6),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        opacity: widget.visible ? 1 : 0,
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              decoration: BoxDecoration(
                // 半透明而不是实色：用户还要透过它看歌词。
                color: widget.backgroundColor.withValues(alpha: 0.86),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: fg.withValues(alpha: 0.10),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // 当前值 + 方向，紧凑一行。
                  Row(
                    children: <Widget>[
                      Text(
                        _formatMs(shown),
                        style: TextStyle(
                          color: fg,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _directionLabel(shown),
                          style: TextStyle(
                            color: fg.withValues(alpha: 0.55),
                            fontSize: 11,
                          ),
                        ),
                      ),
                      if (_adjusted)
                        GestureDetector(
                          onTap: () {
                            _touch();
                            widget.onReset();
                          },
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            child: Icon(
                              Icons.restart_alt,
                              size: 18,
                              color: fg.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                      overlayColor: fg.withValues(alpha: 0.10),
                      activeTrackColor: fg.withValues(alpha: 0.55),
                      inactiveTrackColor: fg.withValues(alpha: 0.16),
                      thumbColor: fg,
                    ),
                    child: Slider(
                      // 已提交的偏移可能超出半量程（早期手动拖到 ±40 秒），
                      // 此时把滑块拉回边界，否则 Slider 会因 value 越界而抛断言。
                      value: shown
                          .toDouble()
                          .clamp(-_sliderSpanMs.toDouble(), _sliderSpanMs.toDouble()),
                      min: -_sliderSpanMs.toDouble(),
                      max: _sliderSpanMs.toDouble(),
                      divisions: _sliderSpanMs ~/ 100 * 2,
                      onChanged: (double v) {
                        _touch();
                        _set(v.round());
                      },
                      onChangeEnd: (double v) {
                        _touch();
                        _set(v.round(), commit: true);
                      },
                    ),
                  ),
                  const SizedBox(height: 2),
                  // 步进按键：**外侧粗、内侧细**。
                  //
                  // 100ms 是听歌词对行时的最小可辨粒度（人耳对 50ms 内的先后基本
                  // 分不出来），所以最细只给 100ms，再细就是拿手指头当示波器；
                  // 500ms 用来快速离开一个明显错开的起点。
                  Row(
                    children: <Widget>[
                      _StepKey(
                        icon: Icons.keyboard_double_arrow_left,
                        label: '0.5',
                        onPressed: () => _nudge(-500),
                      ),
                      _StepKey(
                        icon: Icons.chevron_left,
                        label: '0.1',
                        onPressed: () => _nudge(-100),
                      ),
                      _StepKey(
                        icon: Icons.restart_alt,
                        label: '归零',
                        emphasized: true,
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          _touch();
                          _set(0, commit: true);
                        },
                      ),
                      _StepKey(
                        icon: Icons.chevron_right,
                        label: '0.1',
                        onPressed: () => _nudge(100),
                      ),
                      _StepKey(
                        icon: Icons.keyboard_double_arrow_right,
                        label: '0.5',
                        onPressed: () => _nudge(500),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 步进按键：图标给方向与量级，下方小字给出确切步长。
///
/// 五个键等宽平铺（而不是自然宽度），理由是**盲操作**：眼睛盯着歌词听歌时，
/// 靠的是「我知道它在左边第几个」而不是精确看每个键的位置，等宽才能让
/// 「第 2 个 = 0.1 秒」这种肌肉记忆成立。最小点按区 40×40。
class _StepKey extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// 「归零」用主色实底：它是**语义不同**的动作（回基准），
  /// 混在四个「微调」里视觉上要能一眼分开。
  final bool emphasized;

  const _StepKey({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color fg = emphasized ? scheme.onPrimary : scheme.onSurface;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 4),
            minimumSize: const Size(0, 40),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
            ),
            backgroundColor: emphasized
                ? scheme.primary
                : scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            foregroundColor: fg,
          ),
          // 纵排：图标在上、步长在下。横排五列时标签只能给 2~3 个字符，
          // 「0.5 秒」会被迫省略成让人猜不出量级的短标签。
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 16),
              const SizedBox(height: 1),
              Text(
                label,
                style: TextStyle(fontSize: 9.5, color: fg, height: 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 把毫秒说成人话：大单位优先，避免出现 `+1200ms` 这种没人愿意读的字样。
String _formatMs(int ms) {
  if (ms == 0) return '0 秒';
  final String sign = ms > 0 ? '+' : '−';
  final int abs = ms.abs();
  if (abs >= 1000) {
    final double seconds = abs / 1000;
    // 整秒不显示小数（`+2 秒` 而不是 `+2.0 秒`），非整秒保留一位。
    final String text = seconds == seconds.roundToDouble()
        ? seconds.round().toString()
        : seconds.toStringAsFixed(1);
    return '$sign$text 秒';
  }
  return '$sign$abs 毫秒';
}

String _directionLabel(int ms) {
  if (ms == 0) return '与歌曲对齐';
  return ms > 0 ? '歌词延后' : '歌词提前';
}
