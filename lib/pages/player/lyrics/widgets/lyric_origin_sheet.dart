import 'package:flutter/material.dart';

import '../../../../app/services/lyrics/lyric_origin.dart';
import '../../../../app/services/lyrics/online_lyric_source.dart';
import '../../../../components/common/setting_widgets.dart';

/// 「这份歌词是哪来的」详情面板；返回 `true` 表示用户要求重新匹配。
///
/// 为什么值得单独做个面板：这个曲库的歌词**全部靠跨歌手采纳**拿到（曲库里的歌手
/// 是翻唱者，歌词库里只有原唱条目），所以「配到的是谁的版本」直接决定这份词对不对。
/// 以前这些信息只打在 debug 日志里，用户看到明显错位的歌词时，既不知道它从哪来、
/// 也不知道配的是哪一版，更没有换一份的办法。
Future<bool?> showLyricOriginSheet({
  required BuildContext context,
  required String songTitle,
  required LyricOrigin? origin,
  required bool hasLyric,
  required bool onlineEnabled,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) {
      final ColorScheme scheme = Theme.of(sheetContext).colorScheme;
      final List<Widget> rows = <Widget>[];

      if (hasLyric) {
        rows.add(
          _row(
            sheetContext,
            '歌词来源',
            origin == null
                ? '音乐库'
                : OnlineLyricSource.instance.displayNameFor(origin.sourceId),
          ),
        );
        if (origin != null) {
          final String? matched = _matchedLabel(origin);
          if (matched != null) {
            rows.add(_row(sheetContext, '匹配到的版本', matched));
          }
          if (origin.deltaMs != null) {
            rows.add(_row(sheetContext, '时长差', _seconds(origin.deltaMs!)));
          }
          final String? fmt = _formatLabel(origin.format);
          if (fmt != null) {
            rows.add(_row(sheetContext, '歌词形式', fmt));
          }
          rows.add(_row(sheetContext, '匹配时间', _date(origin.at)));
        }
      } else {
        rows.add(
          _row(
            sheetContext,
            '歌词来源',
            '没有找到',
          ),
        );
      }

      return AppSheetPanel(
        title: '歌词来源',
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                songTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              AppSettingSection(
                children: rows,
              ),
              const SizedBox(height: 16),
              Text(
                _explain(hasLyric: hasLyric, origin: origin, onlineEnabled: onlineEnabled),
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => Navigator.of(sheetContext).pop(true),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新匹配歌词'),
              ),
              const SizedBox(height: 8),
              Text(
                '会清掉这首歌在音乐库与在线两侧的缓存，再从头找一遍。'
                '只影响这一首歌，不动你在服务器上的任何文件。',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 11,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 说明文字：把「现在是什么情况、该怎么办」讲清楚。
String _explain({
  required bool hasLyric,
  required LyricOrigin? origin,
  required bool onlineEnabled,
}) {
  if (!hasLyric) {
    if (!onlineEnabled) {
      return '这首歌找不到歌词，而且「曲库没有歌词时联网刮削」这个开关是关着的 ——'
          '先去歌词设置里打开它，再回来重新匹配。';
    }
    return '音乐库和六个在线渠道都没找到这首歌的歌词。'
        '常见原因：这是片段或清唱版、曲目时长与任何收录版本都差得太远、'
        '或者歌名与歌词库里的写法不一致。点下面的按钮可以重新找一遍。';
  }
  if (origin == null) {
    return '这份歌词来自音乐库本身（或它已在本机的缓存），不是联网刮来的。'
        '如果嫌它不准，点下面的按钮会把它连同在线歌词一起清掉重找。';
  }
  return '这份歌词是联网刮来的：曲库里没有，所以按「歌名一致 + 时长贴合」'
      '从在线曲库采纳的。这个曲库的歌手是翻唱者，在线只有原唱条目，'
      '所以匹配到的版本歌手必然不同 —— 时长差越小，时间轴越可信。'
      '如果明显配错了，点下面重新找一遍。';
}

String? _matchedLabel(LyricOrigin origin) {
  final String? title = origin.matchedTitle;
  final String? artist = origin.matchedArtist;
  if (title == null || title.trim().isEmpty) {
    return artist == null || artist.trim().isEmpty ? null : artist;
  }
  if (artist == null || artist.trim().isEmpty) return '《$title》';
  return '《$title》· $artist';
}

String _seconds(int ms) {
  final double s = ms / 1000;
  return '${s.toStringAsFixed(1)} 秒';
}

String? _formatLabel(String? format) {
  switch (format) {
    case 'wordSynced':
      return '逐字';
    case 'lineSynced':
      return '整行';
    case 'plain':
      return '纯文本';
    default:
      return null;
  }
}

String _date(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}

Widget _row(BuildContext context, String label, String value) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 78,
          child: Text(
            label,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(color: scheme.onSurface, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}
