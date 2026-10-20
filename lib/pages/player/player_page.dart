import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lyric/core/lyric_model.dart' as fl;
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/router/app_router.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/lyrics/lyrics_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/layout_settings.dart';
import '../../app/state/player_state.dart';
import '../../app/state/player_style_settings.dart';
import '../../app/state/song_state.dart';
import '../../components/common/artwork_widget.dart';
import '../../components/player/lyric_preview.dart';
import 'lyrics/lyric_view.dart';
import 'widgets/album_swipe_layer.dart';
import 'widgets/player_background.dart';
import 'widgets/player_bottom_panel.dart';
import 'widgets/player_header.dart';

/// 窗口宽度断点（小米大屏适配标准，同 Material Design）：
///
/// - **< 600 小屏**（手机 / 车机 1/3 窗口）：单窗格，封面与控制上下竖排；
/// - **600-839 中屏**（车机 2/3 窗口等）：双窗格，封面与控制左右分栏；
/// - **≥ 840 大屏**（车机全屏）：三窗格，封面 | 控制 | 歌词常显。
///
/// 车机妙享桌面柔性窗口的三种尺寸（1/3、2/3、全屏）正好落在这三档里
/// （16 寸 16:10 屏约 1440×900dp：1/3≈480、2/3≈960、全屏≈1440）。
const double kPlayerMediumBreakpoint = 600;
const double kPlayerExpandedBreakpoint = 840;

/// 全屏播放器页面。
///
/// 结构：拖拽下拉关闭 + 渐变背景（[PlayerBackground]）+ 主题覆盖（[PlayerTheme]）
/// + 经典 / 海报两种布局。底部面板与播放器样式设置由 [PlayerStyleSettings] 控制。
///
/// 封面页 ⇄ 歌词页是**重叠淡入淡出**（不是翻页转场）：两页同时挂在
/// [Stack] 里用透明度交叉，参考网易云音乐的切换手感。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with TickerProviderStateMixin {
  final FnPlayerService _player = FnPlayerService.instance;

  /// 封面页 / 歌词页的交叉淡入淡出进度：0 = 封面页，1 = 歌词页。
  ///
  /// 两页始终同时挂载在 [Stack] 里（隐藏那页不构建），切换就是透明度
  /// 交叉 —— 没有翻页位移，参考网易云音乐。
  late final AnimationController _pageFade;

  /// 当前下拉位移（用于 Transform.translate / Opacity / ClipRRect）。
  final ValueNotifier<double> _dismissOffset = ValueNotifier<double>(0);

  /// 无界动画控制器：驱动下拉关闭动画（unbounded 才能在任意起点收放）。
  late final AnimationController _dismissController;
  double _dragStartOffset = 0;
  Offset _dragStartPosition = Offset.zero;
  bool _closing = false;

  /// M 键静音状态（车机遥控器盲操，无音量 UI，记在页面里即可）。
  bool _muted = false;

  /// 下拉超过屏幕高度的这一比例即松手关闭。
  double get _dismissThreshold => MediaQuery.sizeOf(context).height * 0.3;

  Signal<SongEntity?> get _songSignal =>
      AppPlayerState.instance.currentSongSignal;

  @override
  void initState() {
    super.initState();
    _pageFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 0,
    );
    _pageFade.addStatusListener(_onPageFadeStatus);
    _dismissController = AnimationController.unbounded(vsync: this);
    PlayerStyleSettings.ensureLoaded();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLayoutSettings.playerRouteActive.value = true;
    });
  }

  @override
  void dispose() {
    _pageFade.removeStatusListener(_onPageFadeStatus);
    _pageFade.dispose();
    _dismissController.dispose();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLayoutSettings.playerRouteActive.value = false;
    });
    super.dispose();
  }

  void _onPageFadeStatus(AnimationStatus status) {
    // 回到封面页（反向动画结束）：释放全局拖动选中状态。
    // LyricController 是全局单例，歌词页拖动选中后若直接切回封面页，
    // 残留状态会传染给共享 controller 的歌词预览（底栏迷你歌词）。
    if (status == AnimationStatus.dismissed) {
      LyricsService.instance.controller.stopSelection();
    }
  }

  // ---------- 封面页 ⇄ 歌词页（淡入淡出，可打断）----------

  /// 切到歌词页。动画进行中再点 = 从当前透明度继续（可打断）。
  Future<void> _openLyricsPage() async {
    if (_pageFade.value > 0.99) return;
    await _pageFade.forward();
  }

  /// 回到封面页。
  Future<void> _closeLyricsPage() async {
    if (_pageFade.value < 0.01) return;
    await _pageFade.reverse();
  }

  // ---------- 拖拽下拉关闭 ----------

  void _handleDismissDragStart(DragStartDetails details) {
    if (_closing) return;
    _dismissController.stop();
    _dragStartOffset = _dismissOffset.value;
    _dragStartPosition = details.globalPosition;
  }

  void _handleDismissDragUpdate(DragUpdateDetails details) {
    if (_closing) return;
    final double dy = details.globalPosition.dy - _dragStartPosition.dy;
    _dismissOffset.value = math.max(0, _dragStartOffset + dy);
  }

  void _handleDismissDragEnd(DragEndDetails details) {
    if (_closing) return;
    final double velocity = details.primaryVelocity ?? 0;
    if (_dismissOffset.value > _dismissThreshold || velocity > 1000) {
      _closePlayer();
    } else {
      _animateDismissOffset(0);
    }
  }

  void _handleDismissDragCancel() {
    if (_closing) return;
    _animateDismissOffset(0);
  }

  Future<void> _animateDismissOffset(double target) {
    final double begin = _dismissOffset.value;
    if (begin == target || _closing) return Future<void>.value();
    _dismissController.stop();
    _dismissController.value = 0;
    final Animation<double> animation = Tween<double>(begin: begin, end: target)
        .animate(
          CurvedAnimation(
            parent: _dismissController,
            curve: Curves.easeOutCubic,
          ),
        );
    void listener() {
      _dismissOffset.value = animation.value;
    }

    _dismissController.addListener(listener);
    return _dismissController
        .animateTo(1, duration: const Duration(milliseconds: 220))
        .whenComplete(() {
          _dismissController.removeListener(listener);
          _dismissOffset.value = target;
        });
  }

  /// 下拉关闭：先动画滑出，再 pop；根路由时退回首页。
  Future<void> _closePlayer() async {
    if (_closing) return;
    _closing = true;
    await _animateDismissOffset(MediaQuery.sizeOf(context).height);
    if (!mounted) return;
    final NavigatorState navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      navigator.pushReplacementNamed(AppRoutes.home);
    }
  }

  // ---------- 键盘快捷键（车机遥控器 / D-pad / 物理键盘）----------

  /// 相对当前位置 seek（键盘快捷键用）。
  void _seekBy(Duration offset) {
    final Duration position = AppPlayerState.instance.positionSignal.value;
    final Duration? duration = AppPlayerState.instance.durationSignal.value;
    if (duration == null || duration <= Duration.zero) return;
    final int targetMs = (position.inMilliseconds + offset.inMilliseconds)
        .clamp(0, duration.inMilliseconds);
    _player.seek(Duration(milliseconds: targetMs));
  }

  /// M 键静音切换（小米大屏 UX 标准 L2 媒体场景要求）。
  ///
  /// 应用没有音量 UI，取消静音回到 1.0；盲操按键给一条轻提示反馈。
  void _toggleMute() {
    _muted = !_muted;
    _player.setVolume(_muted ? 0 : 1.0);
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    messenger?.showSnackBar(
      SnackBar(
        content: Text(_muted ? '已静音' : '已取消静音'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    // 键盘快捷键（车机遥控器 / D-pad / 物理键盘）：
    // 空格 = 播放/暂停，左右方向键 = 快退/快进 10 秒，
    // Esc = 退出全屏（收起播放页），M = 静音。
    // 小米大屏 UX 标准 L2 的媒体播放场景要求。
    return CallbackShortcuts(
      bindings: <LogicalKeySet, VoidCallback>{
        LogicalKeySet(LogicalKeyboardKey.space): () {
          _player.togglePlayPause();
        },
        LogicalKeySet(LogicalKeyboardKey.arrowLeft): () {
          _seekBy(const Duration(seconds: -10));
        },
        LogicalKeySet(LogicalKeyboardKey.arrowRight): () {
          _seekBy(const Duration(seconds: 10));
        },
        LogicalKeySet(LogicalKeyboardKey.escape): () {
          _closePlayer();
        },
        LogicalKeySet(LogicalKeyboardKey.keyM): () {
          _toggleMute();
        },
      },
      child: _buildPage(),
    );
  }

  Widget _buildPage() {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _closePlayer();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: ValueListenableBuilder<double>(
          valueListenable: _dismissOffset,
          builder: (context, offset, _) {
            final double progress = (offset / _dismissThreshold).clamp(
              0.0,
              1.0,
            );
            return Transform.translate(
              offset: Offset(0, offset),
              child: Opacity(
                opacity: 1 - progress * 0.08,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(progress * 24),
                  child: _buildMainContent(context),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildMainContent(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: RepaintBoundary(
            child: PlayerBackground(songSignal: _songSignal),
          ),
        ),
        RepaintBoundary(
          child: PlayerTheme(
            child: ValueListenableBuilder<PlayerStylePreset>(
              valueListenable: PlayerStyleSettings.stylePreset,
              builder: (context, preset, _) {
                final bool isPoster = preset == PlayerStylePreset.poster;
                // 大屏一律走经典三窗格：海报样式是为竖屏手机设计的，
                // 拉到车机全屏没有意义（大封面 + 拉伸的信息区）。
                final bool expanded =
                    MediaQuery.sizeOf(context).width >=
                    kPlayerExpandedBreakpoint;
                final bool posterStyle = isPoster && !expanded;
                return SafeArea(
                  top: !posterStyle,
                  bottom: false,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onVerticalDragStart: _handleDismissDragStart,
                    onVerticalDragUpdate: _handleDismissDragUpdate,
                    onVerticalDragEnd: _handleDismissDragEnd,
                    onVerticalDragCancel: _handleDismissDragCancel,
                    child: Column(
                      children: <Widget>[
                        if (!posterStyle) PlayerHeader(songSignal: _songSignal),
                        Expanded(
                          child: expanded
                              // 大屏：三窗格（歌词常显），无需淡入淡出切换
                              ? _MobilePlayerLayout(
                                  player: _player,
                                  songSignal: _songSignal,
                                  stylePreset: preset,
                                  onTapLyrics: _openLyricsPage,
                                  showLyricsPane: true,
                                )
                              : _buildCrossfadeStage(posterStyle, preset),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        if (Platform.isWindows)
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 8, left: 8),
                child: BackButton(onPressed: _closePlayer),
              ),
            ),
          ),
      ],
    );
  }

  /// 封面页 ⇄ 歌词页：重叠淡入淡出（参考网易云音乐）。
  ///
  /// 两页同时挂在 [Stack] 里，用 [_pageFade] 驱动透明度交叉；
  /// 隐藏的那页不构建（省绘制），过半透明度的页可交互。
  Widget _buildCrossfadeStage(bool posterStyle, PlayerStylePreset preset) {
    return AnimatedBuilder(
      animation: _pageFade,
      builder: (BuildContext context, Widget? child) {
        final double t = _pageFade.value;
        return Stack(
          children: <Widget>[
            if (t < 1)
              Positioned.fill(
                child: Opacity(
                  opacity: 1 - t,
                  child: IgnorePointer(
                    ignoring: t > 0.5,
                    child: posterStyle
                        ? _PosterPlayerLayout(
                            player: _player,
                            songSignal: _songSignal,
                            onTapLyrics: _openLyricsPage,
                          )
                        : _MobilePlayerLayout(
                            player: _player,
                            songSignal: _songSignal,
                            stylePreset: preset,
                            onTapLyrics: _openLyricsPage,
                          ),
                  ),
                ),
              ),
            if (t > 0)
              Positioned.fill(
                child: Opacity(
                  opacity: t,
                  child: IgnorePointer(
                    ignoring: t < 0.5,
                    child: _buildLyricsPage(posterStyle),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildLyricsPage(bool posterStyle) {
    // 海报样式关闭了 SafeArea 顶部（封面延伸到屏幕边缘），歌词页
    // 手动补回顶部/底部 inset，防止歌词行滑入状态栏或导航栏下方。
    if (posterStyle) {
      return Padding(
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top,
          bottom: MediaQuery.paddingOf(context).bottom,
        ),
        child: PlayerLyricsView(
          showControls: true,
          fadeEdges: true,
          onTapLine: _closeLyricsPage,
        ),
      );
    }
    return PlayerLyricsView(
      showControls: true,
      fadeEdges: true,
      onTapLine: _closeLyricsPage,
    );
  }
}

/// 经典布局：按窗口宽度三档排布。
///
/// - 竖屏（< 600dp，手机 / 车机 1/3 窗口）：封面轮播在上，控制面板在下；
/// - 中屏（600-839dp，车机 2/3 窗口等）：封面在左，控制在右；
/// - 大屏（≥ 840dp，车机全屏）：三窗格 —— 封面 | 控制 | 歌词常显。
///
/// 竖屏布局在横屏下会把封面压成宽扁条、底部面板占掉半屏，车机大屏上
/// 尤其难看。分栏后封面保持正方形、控制区获得独立列宽。
class _MobilePlayerLayout extends StatelessWidget {
  final FnPlayerService player;
  final Signal<SongEntity?> songSignal;
  final PlayerStylePreset stylePreset;
  final VoidCallback onTapLyrics;

  /// 大屏：歌词常显第三窗格（封面 ⇄ 歌词的淡入淡出切换不再需要）。
  final bool showLyricsPane;

  const _MobilePlayerLayout({
    required this.player,
    required this.songSignal,
    required this.stylePreset,
    required this.onTapLyrics,
    this.showLyricsPane = false,
  });

  @override
  Widget build(BuildContext context) {
    if (showLyricsPane) return _buildExpanded();
    final double width = MediaQuery.sizeOf(context).width;
    if (width >= kPlayerMediumBreakpoint) return _buildSplit();
    return _buildPortrait();
  }

  Widget _buildPortrait() {
    return Column(
      children: <Widget>[
        Expanded(child: _buildSwipeStage()),
        PlayerBottomPanel(
          player: player,
          stylePreset: stylePreset,
          onTapLyrics: onTapLyrics,
        ),
      ],
    );
  }

  Widget _buildSplit() {
    return Padding(
      // 横向下高度是瓶颈，封面不再用大内边距，给正方形封面留空间。
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          // 左侧：封面轮播（正方形，受高度约束）。
          Expanded(flex: 5, child: _buildSwipeStage()),
          const SizedBox(width: 16),
          // 右侧：进度 + 控制 + 操作。隐藏迷你歌词 —— 歌词页仍可
          // 点击进入，横屏空间宝贵，不重复占一行。
          Expanded(
            flex: 4,
            child: PlayerBottomPanel(
              player: player,
              stylePreset: stylePreset,
              onTapLyrics: onTapLyrics,
              showMiniLyrics: false,
            ),
          ),
        ],
      ),
    );
  }

  /// 大屏三窗格：封面 | 控制 | 歌词（常显）。
  Widget _buildExpanded() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(flex: 5, child: _buildSwipeStage()),
          const SizedBox(width: 20),
          Expanded(
            flex: 4,
            child: Center(
              child: PlayerBottomPanel(
                player: player,
                stylePreset: stylePreset,
                onTapLyrics: onTapLyrics,
                showMiniLyrics: false,
              ),
            ),
          ),
          const SizedBox(width: 20),
          // 歌词常显：点歌词行 = 跳转到该句（默认行为），
          // 控制在中间窗格，这里不重复挂控件。
          Expanded(
            flex: 5,
            child: PlayerLyricsView(showControls: false, fadeEdges: true),
          ),
        ],
      ),
    );
  }

  /// 封面轮播舞台：横向拖动切歌（网易云式跟手轮播）。
  Widget _buildSwipeStage() {
    return Watch.builder(
      builder: (BuildContext context) {
        final SongEntity? song = songSignal.value;
        // 显式读取队列 / 索引信号：peek 结果依赖它们，
        // 不读的话队列变化（增删曲、换模式）不会刷新预读封面。
        final List<SongEntity> queue =
            AppPlayerState.instance.queueSignal.value;
        final int index = AppPlayerState.instance.currentIndexSignal.value;
        if (queue.isEmpty || index < 0 || index >= queue.length) {
          // 无有效队列：纯封面，不挂手势层。
          return _buildCover(song, isPlaying: false);
        }
        final bool isPlaying = AppPlayerState.instance.isPlayingSignal.value;
        return AlbumSwipeLayer(
          onNext: player.next,
          onPrevious: player.previousTrack,
          onTap: onTapLyrics,
          currentSong: song,
          currentCover: _buildCover(song, isPlaying: isPlaying),
          nextCover: _coverOrNull(player.peekNext()),
          previousCover: _coverOrNull(player.peekPrevious()),
        );
      },
    );
  }

  Widget? _coverOrNull(SongEntity? song) =>
      song == null ? null : _buildCover(song, isPlaying: false);

  /// 封面部件（纯函数式：显式歌曲 + 显式播放态，不读全局信号 ——
  /// 切歌轮播要在提交时捕获「那一刻的画面」，活部件会跟着变）。
  Widget _buildCover(SongEntity? song, {required bool isPlaying}) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        PlayerBackgroundSettings.roundCover,
        PlayerBackgroundSettings.rotateCover,
      ]),
      builder: (BuildContext context, Widget? child) {
        final bool roundCover = PlayerBackgroundSettings.roundCover.value;
        final bool rotateCover = PlayerBackgroundSettings.rotateCover.value;
        final Widget artwork = _buildArtwork(song, roundCover);
        if (isPlaying && rotateCover && roundCover) {
          return _RotatingArtwork(child: artwork);
        }
        return artwork;
      },
    );
  }

  Widget _buildArtwork(SongEntity? song, bool roundCover) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 轮播槽位是正方形，封面铺满槽位（跟手时相邻封面紧贴，
        // 传送带效果；不再用 32px 内边距，否则槽间会出现缝隙）。
        final double size = constraints.biggest.shortestSide;
        return SizedBox(
          width: size,
          height: size,
          child: ArtworkWidget(
            imageUrl: ApiClient.instance.coverUrl(song?.coverId),
            size: size,
            borderRadius: roundCover
                ? BorderRadius.circular(size / 2)
                : BorderRadius.circular(12),
          ),
        );
      },
    );
  }
}

/// 旋转封面：20s 一圈，持续旋转。
class _RotatingArtwork extends StatefulWidget {
  final Widget child;

  const _RotatingArtwork({required this.child});

  @override
  State<_RotatingArtwork> createState() => _RotatingArtworkState();
}

class _RotatingArtworkState extends State<_RotatingArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) =>
          RotationTransition(turns: _controller, child: child),
      child: widget.child,
    );
  }
}

/// 海报布局：大封面铺顶 + 歌词预览 + 底部信息 / 进度 / 控制。
///
/// 封面区是滑动轮播舞台（与经典布局同一套跟手切歌交互）。
class _PosterPlayerLayout extends StatelessWidget {
  final FnPlayerService player;
  final Signal<SongEntity?> songSignal;
  final VoidCallback onTapLyrics;

  const _PosterPlayerLayout({
    required this.player,
    required this.songSignal,
    required this.onTapLyrics,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double heroHeight = (MediaQuery.sizeOf(context).height * 0.40).clamp(
      240.0,
      400.0,
    );
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    final double bottomPad = bottomInset > 20 ? bottomInset + 8 : 18;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 固定高度封面区（滑动轮播舞台）。
        SizedBox(height: heroHeight, child: _buildSwipeStage(heroHeight)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Watch.builder(
                  builder: (context) {
                    final SongEntity? song = songSignal.value;
                    final String title = song?.title.trim().isEmpty == true
                        ? '未知歌曲'
                        : (song?.title ?? '未知歌曲');
                    return Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Watch.builder(
                  builder: (context) {
                    final SongEntity? song = songSignal.value;
                    final String artist =
                        song?.artistDisplay?.trim().isEmpty == true
                        ? '未知歌手'
                        : (song?.artistDisplay ?? '未知歌手');
                    return Text(
                      artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                      ),
                    );
                  },
                ),
              ),
              // 歌词预览：弹性占满「标题之下、控制区之上」的剩余空间，
              // 空间不足时收缩。点击跳转到歌词页（与底栏迷你歌词一致）。
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTapLyrics,
                  child: _PosterLyricsPreview(),
                ),
              ),
              _PosterMetaRow(player: player, songSignal: songSignal),
              const SizedBox(height: 8),
              PlayerSeekBar(player: player),
              const SizedBox(height: 12),
              PosterControls(player: player),
              SizedBox(height: bottomPad),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSwipeStage(double heroHeight) {
    return Watch.builder(
      builder: (BuildContext context) {
        final SongEntity? song = songSignal.value;
        final List<SongEntity> queue =
            AppPlayerState.instance.queueSignal.value;
        final int index = AppPlayerState.instance.currentIndexSignal.value;
        if (queue.isEmpty || index < 0 || index >= queue.length) {
          return _buildPosterCover(song, heroHeight);
        }
        return AlbumSwipeLayer(
          onNext: player.next,
          onPrevious: player.previousTrack,
          onTap: onTapLyrics,
          currentSong: song,
          currentCover: _buildPosterCover(song, heroHeight),
          nextCover: _coverOrNull(player.peekNext(), heroHeight),
          previousCover: _coverOrNull(player.peekPrevious(), heroHeight),
        );
      },
    );
  }

  Widget? _coverOrNull(SongEntity? song, double heroHeight) =>
      song == null ? null : _buildPosterCover(song, heroHeight);

  /// 海报大封面：方形铺满槽位，顶部做渐隐融入背景。
  Widget _buildPosterCover(SongEntity? song, double heroHeight) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double size = constraints.biggest.shortestSide;
        return SizedBox(
          width: size,
          height: size,
          child: ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (Rect bounds) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.transparent,
                Colors.white,
                Colors.white,
                Colors.white,
              ],
              stops: <double>[0.0, 0.62, 0.88, 1.0],
            ).createShader(bounds),
            child: ArtworkWidget(
              imageUrl: ApiClient.instance.coverUrl(song?.coverId),
              size: size,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      },
    );
  }
}

/// 海报布局的歌词预览（标题之下、控制区之上）。
class _PosterLyricsPreview extends StatelessWidget {
  const _PosterLyricsPreview();

  @override
  Widget build(BuildContext context) {
    return Watch.builder(
      builder: (context) {
        final LyricsService lyrics = LyricsService.instance;
        final LyricsSnapshot snap = lyrics.snapshotSignal.value;
        final fl.LyricModel? model = lyrics.lyricModelSignal.value;
        final List<fl.LyricLine> lines = model?.lines ?? const <fl.LyricLine>[];
        // 加载新歌歌词时保持空白，歌词就绪后直接展示真实行。
        if (snap.status == LyricsLoadStatus.loading && lines.isEmpty) {
          return const SizedBox.shrink();
        }
        if (lines.isEmpty) {
          // 标题/歌手已在上方展示，这里用中性占位，避免重复。
          return const Align(
            alignment: Alignment.topLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PosterLyricLine(text: '暂无歌词', active: true),
                SizedBox(height: 8),
                _PosterLyricLine(text: '纯音乐或未匹配到歌词', active: false),
                SizedBox(height: 8),
                _PosterLyricLine(text: ' ', active: false),
              ],
            ),
          );
        }

        // 复用歌词页的 LyricView 渲染管线，保证与歌词页一致的流畅逐字动画。
        // LayoutBuilder 读取实际可用高度：海报布局中该预览区是弹性空间，
        // 矮屏/大字体机型下会收缩而不是溢出。外层 Container 已带水平内边距，
        // contentPadding: EdgeInsets.zero 让歌词与标题左对齐。
        return LayoutBuilder(
          builder: (context, constraints) {
            final double h = constraints.hasBoundedHeight
                ? constraints.maxHeight
                : 118.0;
            return LyricPreview(
              height: h.clamp(0.0, 1000.0),
              textAlign: TextAlign.start,
              contentAlignment: CrossAxisAlignment.start,
              showTranslation: true,
              fontSize: 15,
              activeFontSize: 18,
              contentPadding: EdgeInsets.zero,
              fadeEdges: true,
            );
          },
        );
      },
    );
  }
}

class _PosterLyricLine extends StatelessWidget {
  final String text;
  final bool active;

  const _PosterLyricLine({required this.text, required this.active});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: active
            ? scheme.onSurface.withValues(alpha: 0.92)
            : scheme.onSurfaceVariant.withValues(alpha: 0.68),
        fontSize: active ? 18 : 15,
        fontWeight: active ? FontWeight.w800 : FontWeight.w600,
        height: 1.15,
      ),
    );
  }
}

/// 海报布局信息行：收藏 + 播放队列。
class _PosterMetaRow extends StatelessWidget {
  final FnPlayerService player;
  final Signal<SongEntity?> songSignal;

  const _PosterMetaRow({required this.player, required this.songSignal});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        FavoriteButton(songSignal: songSignal),
        IconButton(
          icon: const Icon(Icons.format_list_bulleted_rounded),
          onPressed: () => showPlayerPlaylistSheet(context, player),
        ),
      ],
    );
  }
}
