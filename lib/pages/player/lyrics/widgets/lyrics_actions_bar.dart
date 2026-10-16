import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

/// 歌词页底部那一行：左边「词」（打开歌词设置）、中间是**这份歌词的来历**、
/// 右边「译」（有翻译时才出现）。
///
/// 中间那行字为什么值得占位置：这个曲库的歌词全部靠「跨歌手采纳」拿到（曲库里的
/// 歌手是翻唱者，歌词库里只有原唱条目），所以「配到的是谁的版本」直接决定这份词
/// 对不对。以前这个信息只存在于 debug 日志，用户看到明显配错的歌词时，既不知道
/// 它从哪来、也没有换一份的办法。
class LyricsActionsBar extends StatelessWidget {
  final bool hasTranslation;
  final bool showTranslation;
  final VoidCallback onOpenSettings;
  final VoidCallback onToggleTranslation;

  /// 中间那行来历说明。为 null 时不占位。
  final String? originText;

  /// 点中间那行 —— 打开来源详情（里面可以重新匹配）。
  final VoidCallback? onTapOrigin;

  /// 「时」徽标的位置放什么。传 null 则用内置的默认徽标。
  ///
  /// 做成 slot 而不是把状态直接传进来，是为了**重建隔离**：歌词页用
  /// `OffsetBadgeSignal` 塞进来一枚会自行订阅 signal 的徽标，展开/收起微调
  /// 浮层时只有这一枚重绘 —— 若改成整条操作栏跟随重建，正在滚动的歌词页会
  /// 跟着抖一下（实测过，很难看）。
  final Widget? offsetBar;

  final Color color;
  final bool originHighlighted;

  const LyricsActionsBar({
    super.key,
    required this.hasTranslation,
    required this.showTranslation,
    required this.onOpenSettings,
    required this.onToggleTranslation,
    required this.color,
    this.originText,
    this.onTapOrigin,
    this.offsetBar,
    this.originHighlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final String? label = originText;
    return Row(
      children: [
        LyricsBadge(
          text: '词',
          onTap: onOpenSettings,
          color: color,
        ),
        Expanded(
          child: label == null
              ? const SizedBox.shrink()
              : GestureDetector(
                  onTap: onTapOrigin,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: originHighlighted
                            ? color
                            : color.withValues(alpha: 0.72),
                        fontSize: 11,
                        fontWeight: originHighlighted
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
        ),
        // 「时」徽标。必须由外部以 [OffsetBadgeSignal] 的形式传入 ——
        // 它需要自行订阅浮层开合状态才能把重建范围限制在这一枚徽标内，
        // 详见该类的文档。
        if (offsetBar != null) ?offsetBar,
        if (hasTranslation)
          LyricsBadge(
            text: '译',
            isActive: showTranslation,
            onTap: onToggleTranslation,
            color: color,
            filled: true,
          ),
      ],
    );
  }
}

class LyricsBadge extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  final bool isActive;
  final Color color;
  final bool filled;

  /// 强调态：给文字加粗并染色，不改变底色/边框 —— 用于「有异常需注意」而非「已选中」。
  final bool highlight;

  const LyricsBadge({
    super.key,
    required this.text,
    required this.onTap,
    this.isActive = true,
    required this.color,
    this.filled = false,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = filled && isActive;
    final contentColor = isSelected
        ? (color.computeLuminance() > 0.5 ? Colors.black : Colors.white)
        : color;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: isSelected ? color : Colors.transparent,
            border: Border.all(
              color: isSelected ? Colors.transparent : contentColor,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: contentColor,
              fontSize: 11,
              fontWeight: highlight ? FontWeight.w900 : FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

/// 「时」徽标：自己订阅浮层的开合状态。
///
/// ## 为什么要多这一层
///
/// 展开微调浮层时，歌词页**一个字都不该重排**。早先的实现用 `setState` 切浮层，
/// 结果整页重建 —— 正在滚动的歌词会明显「跳一下」，观感很差。
///
/// 把订阅关系收进这一枚徽标自己，展开/收起时 Flutter 只重建它和浮层本身，
/// 歌词列表的 element 完全不受影响。
///
/// ## 两个状态是两件事，别合并
///
/// - [adjusted]：**历史**状态 —— 这首歌被调过偏移（一次会话内、且还没还原）。
///   视觉是**加粗**。
/// - [open]：**开关**状态 —— 浮层此刻正开着（再点会收起）。视觉是**填充**。
///
/// 用户需要一眼分清「我调过它」和「我现在能不能看到控件」，
/// 混成一个视觉会让人不敢点第二次。
class OffsetBadgeSignal extends StatelessWidget {
  final Signal<bool> open;
  final VoidCallback onTap;
  final bool adjusted;
  final Color color;

  const OffsetBadgeSignal({
    super.key,
    required this.open,
    required this.onTap,
    required this.adjusted,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Watch((_) {
      final bool isOpen = open.value;
      return LyricsBadge(
        text: '时',
        onTap: onTap,
        color: color,
        highlight: adjusted,
        filled: true,
        isActive: isOpen,
      );
    });
  }
}
