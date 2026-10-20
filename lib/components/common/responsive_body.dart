import 'package:flutter/material.dart';

/// 宽屏限宽居中的页面 body（小米大屏适配标准「缩进」策略）。
///
/// 有明确顺序的列表（歌曲、设置、统计等）不适合多列排布，宽屏下
/// 直接拉伸会让单行过长、两侧内容难以对应。限宽居中后：
///
/// - 手机 / 车机 1/3 窗口（<600dp）：无副作用（内容本就窄于限宽）；
/// - 车机 2/3 与全屏窗口：内容限宽居中，留白分布在两侧。
class ResponsiveBody extends StatelessWidget {
  final Widget child;

  /// 内容最大宽度（dp）。760 约等于「手机两栏」的舒适阅读宽度。
  final double maxWidth;

  const ResponsiveBody({super.key, required this.child, this.maxWidth = 760});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
