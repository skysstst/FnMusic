import 'package:flutter/material.dart';

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
    this.originHighlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final String? label = originText;
    return Row(
      children: [
        _LyricsBadge(
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
        if (hasTranslation)
          _LyricsBadge(
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

class _LyricsBadge extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  final bool isActive;
  final Color color;
  final bool filled;

  const _LyricsBadge({
    required this.text,
    required this.onTap,
    this.isActive = true,
    required this.color,
    this.filled = false,
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
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
