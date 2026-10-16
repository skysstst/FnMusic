import 'package:flutter/material.dart';

import '../../app/services/lyrics/lyric_offset_store.dart';
import '../../app/services/lyrics/lyrics_service.dart';
import '../../app/services/lyrics/online_lyric_source.dart';
import '../../app/services/lyrics/sources/lyric_source.dart';

/// 歌词设置：歌词刮削（总开关 + 各渠道连通性测试）+ 强制逐字卡拉OK + 自定义歌词配色。
class LyricsSettingsPage extends StatefulWidget {
  const LyricsSettingsPage({super.key});

  static const String route = '/settings/lyrics';

  @override
  State<LyricsSettingsPage> createState() => _LyricsSettingsPageState();
}

class _LyricsSettingsPageState extends State<LyricsSettingsPage> {
  bool _forceKaraoke = false;
  bool _onlineEnabled = true;

  /// 已调整过时间轴偏移的歌曲数。
  int _offsetCount = 0;

  final LyricsService lyrics = LyricsService.instance;

  /// 每个渠道最近一次连通性测试的结果。
  final Map<String, LyricProbeResult> _probes = <String, LyricProbeResult>{};

  /// 正在测的渠道 id。
  final Set<String> _probing = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await LyricsService.instance.refreshSettings();
    await OnlineLyricSource.instance.refreshSettings();
    final int offsets = await lyrics.offsetCount();
    if (!mounted) return;
    setState(() {
      _forceKaraoke = LyricsService.instance.forceKaraoke;
      _onlineEnabled = OnlineLyricSource.instance.enabled;
      _offsetCount = offsets;
    });
  }

  Future<void> _runProbe(LyricSource source) async {
    setState(() => _probing.add(source.id));
    final result = await OnlineLyricSource.instance.probe(source);
    if (!mounted) return;
    setState(() {
      _probing.remove(source.id);
      _probes[source.id] = result;
    });
  }

  Future<void> _pickColor({
    required String title,
    required ValueNotifier<int?> notifier,
  }) async {
    final int? picked = await showDialog<int?>(
      context: context,
      builder: (BuildContext context) => _ColorPickerDialog(
        title: title,
        initial: notifier.value,
      ),
    );
    if (picked == null) return;
    if (picked == _ColorPickerDialog.kFollowTheme) {
      await LyricsService.instance.clearViewColors();
    } else {
      if (identical(notifier, LyricsService.instance.viewInactiveColor)) {
        await LyricsService.instance.setViewColors(inactive: picked);
      } else if (identical(
          notifier, LyricsService.instance.viewActiveColor)) {
        await LyricsService.instance.setViewColors(active: picked);
      } else {
        await LyricsService.instance.setViewColors(highlight: picked);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('歌词设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: <Widget>[
          _SectionHeader('歌词样式'),
          SwitchListTile(
            secondary: const Icon(Icons.format_quote_outlined),
            title: const Text('强制逐字卡拉OK'),
            subtitle: const Text('当前行按字高亮，逐字填充动画'),
            value: _forceKaraoke,
            onChanged: (bool value) async {
              setState(() => _forceKaraoke = value);
              await LyricsService.instance.setForceKaraoke(value);
            },
          ),
          _SectionHeader('歌词配色'),
          ValueListenableBuilder<int?>(
            valueListenable: LyricsService.instance.viewInactiveColor,
            builder: (BuildContext context, int? color, _) {
              return _ColorTile(
                title: '未高亮歌词',
                subtitle: '未播放到行的默认颜色',
                color: color,
                onTap: () => _pickColor(
                  title: '未高亮歌词',
                  notifier: LyricsService.instance.viewInactiveColor,
                ),
              );
            },
          ),
          ValueListenableBuilder<int?>(
            valueListenable: LyricsService.instance.viewActiveColor,
            builder: (BuildContext context, int? color, _) {
              return _ColorTile(
                title: '当前行歌词',
                subtitle: '当前播放行的主色',
                color: color,
                onTap: () => _pickColor(
                  title: '当前行歌词',
                  notifier: LyricsService.instance.viewActiveColor,
                ),
              );
            },
          ),
          ValueListenableBuilder<int?>(
            valueListenable: LyricsService.instance.viewHighlightColor,
            builder: (BuildContext context, int? color, _) {
              return _ColorTile(
                title: '逐字高亮',
                subtitle: '逐字卡拉OK填充色（开启强制逐字时生效）',
                color: color,
                onTap: () => _pickColor(
                  title: '逐字高亮',
                  notifier: LyricsService.instance.viewHighlightColor,
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Text(
              '配色为空时跟随主题色。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          _SectionHeader('歌词刮削'),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_download_outlined),
            title: const Text('曲库没有歌词时联网刮削'),
            subtitle: const Text('开启后按下方渠道依次尝试，结果只缓存在本机'),
            value: _onlineEnabled,
            onChanged: (bool value) async {
              setState(() => _onlineEnabled = value);
              await OnlineLyricSource.instance.setEnabled(value);
            },
          ),
          ..._buildSourceTiles(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Text(
              '点「测试」会用一首大众歌探一次路：能测出这个渠道到底是'
              '「连不上 / 被限流」还是「接口改版了」，与你的曲库无关。\n'
              '歌词来自第三方公开数据源，仅保存在本机，不会写回 NAS；'
              '同名歌曲版本较多时可能出现匹配偏差。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.restore_page_outlined),
            title: const Text('清除失败记录'),
            subtitle: const Text('让之前没找到歌词的歌曲重新联网尝试'),
            onTap: () async {
              // 先取 messenger 再 await，避免跨 async gap 使用 context。
              final messenger = ScaffoldMessenger.of(context);
              await OnlineLyricSource.instance.clearMissCache();
              messenger.showSnackBar(
                const SnackBar(content: Text('已清除失败记录')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.restore_page_outlined),
            title: const Text('清除全部对齐调整'),
            subtitle: Text(
              _offsetCount == 0
                  ? '还没有调整过任何歌词的时间轴'
                  : '已调整 $_offsetCount 首，清除后它们回到歌词自带的偏移',
            ),
            enabled: _offsetCount > 0,
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              await LyricOffsetStore.instance.clear();
              await lyrics.reloadCurrentSong();
              if (!mounted) return;
              setState(() => _offsetCount = 0);
              messenger.showSnackBar(
                const SnackBar(content: Text('已清除全部对齐调整')),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 每个渠道一行：名称 + 说明（或上次测试结果）+ 「测试」按钮。
  ///
  /// 这里**只留测试按钮、不留单个渠道的开关**：开关多了用户不知道到底该关哪个，
  /// 而多渠道本来就是「谁先命中用谁」，关掉某一个只会降低命中率。整块功能由
  /// 上面的总开关一把控制。
  List<Widget> _buildSourceTiles() {
    return OnlineLyricSource.instance.sources.map((LyricSource source) {
      final bool busy = _probing.contains(source.id);
      final LyricProbeResult? probe = _probes[source.id];
      final ColorScheme scheme = Theme.of(context).colorScheme;
      final bool cooling = OnlineLyricSource.instance.isCoolingDown(source.id);

      final String subtitle;
      Color? subtitleColor;
      if (busy) {
        subtitle = '正在测试…';
      } else if (probe != null) {
        subtitle = probe.message;
        subtitleColor = _probeColor(probe.status, scheme);
      } else if (cooling) {
        subtitle = '${source.description}（当前处于限流冷却中）';
        subtitleColor = scheme.error;
      } else {
        subtitle = source.description;
      }

      return ListTile(
        contentPadding: const EdgeInsets.only(left: 36, right: 12),
        leading: _statusDot(busy, probe, scheme),
        title: Text(source.displayName),
        subtitle: Text(
          subtitle,
          style: subtitleColor == null ? null : TextStyle(color: subtitleColor),
        ),
        trailing: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(
                onPressed: _onlineEnabled ? () => _runProbe(source) : null,
                child: const Text('测试'),
              ),
      );
    }).toList();
  }

  Widget _statusDot(bool busy, LyricProbeResult? probe, ColorScheme scheme) {
    if (busy || probe == null) return const SizedBox(width: 10);
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: _probeColor(probe.status, scheme),
        shape: BoxShape.circle,
      ),
    );
  }

  Color _probeColor(LyricProbeStatus status, ColorScheme scheme) {
    switch (status) {
      case LyricProbeStatus.ok:
        return Colors.green.shade600;
      case LyricProbeStatus.rateLimited:
      case LyricProbeStatus.notReady:
      case LyricProbeStatus.noResult:
        return Colors.orange.shade700;
      case LyricProbeStatus.failed:
        return scheme.error;
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

class _ColorTile extends StatelessWidget {
  const _ColorTile({
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final int? color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color == null ? null : Color(color!),
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: color == null
            ? Icon(Icons.auto_awesome,
                size: 16, color: Theme.of(context).colorScheme.outline)
            : null,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// 歌词配色选择对话框。返回 null = 取消；[kFollowTheme] = 恢复跟随主题。
class _ColorPickerDialog extends StatelessWidget {
  const _ColorPickerDialog({required this.title, required this.initial});

  static const int kFollowTheme = -1;

  final String title;
  final int? initial;

  static const List<int> _presets = <int>[
    0xFFFFFFFF, // 白
    0xFF000000, // 黑
    0xFFFF5252, // 红
    0xFFFF7043, // 橙
    0xFFFFC107, // 琥珀
    0xFFCDDC39, // 黄绿
    0xFF66BB6A, // 绿
    0xFF26A69A, // 青
    0xFF29B6F6, // 浅蓝
    0xFF5C6BC0, // 靛蓝
    0xFFAB47BC, // 紫
    0xFFEC407A, // 粉
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: _presets.map((int c) {
              return InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => Navigator.of(context).pop(c),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: initial == c
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
                      width: 3,
                    ),
                  ),
                  child: initial == c
                      ? const Icon(Icons.check, size: 20)
                      : null,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.auto_awesome),
              label: const Text('跟随主题'),
              onPressed: () => Navigator.of(context).pop(kFollowTheme),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
