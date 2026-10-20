import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/services/feiniu/api_client.dart';

/// 封面图组件：支持网络图 + 加载占位 / 失败占位。
///
/// 自动携带当前账号鉴权头（真实 FNOS 的 `/static/cover` 需要 Cookie
/// `music-token`，未登录时为空头，mock/公开封面不受影响）。
class ArtworkWidget extends StatelessWidget {
  const ArtworkWidget({
    super.key,
    this.imageUrl,
    this.size,
    this.borderRadius,
    this.placeholderIcon = Icons.music_note,
    this.placeholderText,
  });

  final String? imageUrl;
  final double? size;
  final BorderRadius? borderRadius;
  final IconData placeholderIcon;

  /// 占位/失败时显示的首字母（无封面图时展示，如专辑名/歌手名首字母）。
  /// 为空则退回 [placeholderIcon] 图标。
  final String? placeholderText;

  @override
  Widget build(BuildContext context) {
    final double? s = size;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // `size: double.infinity` 语义是「铺满父约束」（专辑网格等单元格尺寸
    // 随列数变化的场景）。它不能直接参与字号计算，所以走 LayoutBuilder
    // 取实际约束；其余非有限值仍回退 48，避免占位字号算出 infinity 崩溃。
    if (s != null && !s.isFinite) {
      return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double w = constraints.maxWidth.isFinite && constraints.maxWidth > 0
              ? constraints.maxWidth
              : 48;
          final double h = constraints.maxHeight.isFinite && constraints.maxHeight > 0
              ? constraints.maxHeight
              : w;
          final BorderRadius radius =
              borderRadius ?? BorderRadius.circular(w * 0.22);
          return _render(w, h, radius, scheme);
        },
      );
    }

    final double edge = (s == null || s <= 0) ? 48 : s;
    final BorderRadius radius =
        borderRadius ?? BorderRadius.circular(edge * 0.22);
    return _render(edge, edge, radius, scheme);
  }

  Widget _render(
    double width,
    double height,
    BorderRadius radius,
    ColorScheme scheme,
  ) {
    if (imageUrl == null || imageUrl!.isEmpty) {
      return _placeholder(width, height, radius, scheme);
    }

    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: imageUrl!,
        httpHeaders: ApiClient.imageAuthHeaders(),
        width: width,
        height: height,
        fit: BoxFit.cover,
        placeholder: (context, url) =>
            _placeholder(width, height, radius, scheme),
        errorWidget: (context, url, error) =>
            _placeholder(width, height, radius, scheme),
      ),
    );
  }

  Widget _placeholder(
    double width,
    double height,
    BorderRadius radius,
    ColorScheme scheme,
  ) {
    // 字号/图标以短边为基准：铺满模式下网格单元可能是长方形。
    final double edge = width < height ? width : height;
    final String? text = placeholderText?.trim();
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            scheme.primary.withValues(alpha: 0.18),
            scheme.tertiary.withValues(alpha: 0.12),
          ],
        ),
      ),
      child: (text != null && text.isNotEmpty)
          ? Center(
              child: Text(
                text.substring(0, 1).toUpperCase(),
                style: TextStyle(
                  fontSize: edge * 0.4,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary.withValues(alpha: 0.6),
                ),
              ),
            )
          : Icon(placeholderIcon, size: edge * 0.42, color: scheme.primary.withValues(alpha: 0.5)),
    );
  }
}
