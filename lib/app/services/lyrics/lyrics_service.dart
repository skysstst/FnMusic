import 'package:flutter/foundation.dart';
import 'package:flutter_lyric/core/lyric_controller.dart';
import 'package:flutter_lyric/core/lyric_model.dart' as fl;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals/signals.dart';

import '../../state/player_state.dart';
import '../../state/song_state.dart';
import '../player_service.dart';
import 'lyric_origin.dart';
import 'lyrics_parser.dart';
import 'lyrics_repository.dart';
import 'online_lyric_source.dart';

enum LyricsLoadStatus { idle, loading, loaded, empty, failed }

class LyricsSnapshot {
  final LyricsLoadStatus status;
  final SongEntity? song;
  final fl.LyricModel? model;
  final Object? error;

  const LyricsSnapshot({
    required this.status,
    required this.song,
    required this.model,
    required this.error,
  });

  factory LyricsSnapshot.idle() {
    return const LyricsSnapshot(
      status: LyricsLoadStatus.idle,
      song: null,
      model: null,
      error: null,
    );
  }

  LyricsSnapshot copyWith({
    LyricsLoadStatus? status,
    SongEntity? song,
    Object? error,
    fl.LyricModel? model,
  }) {
    return LyricsSnapshot(
      status: status ?? this.status,
      song: song ?? this.song,
      model: model ?? this.model,
      error: error,
    );
  }
}

/// 歌词服务单例：负责歌词的加载、解析、高亮推进与点按跳转。
///
/// 与播放器的同步通过 [AppPlayerState] 的 ValueNotifier 完成（当前歌曲 /
/// 播放位置 / 播放状态），进度由 [LyricController.setProgress] 驱动。
/// 歌词页与逐字歌词预览共用同一 controller 与配色设置。
class LyricsService {
  static final LyricsService instance = LyricsService._internal();

  static const String _prefsViewForceKaraoke = 'lyrics_view_force_karaoke';
  static const String _prefsViewInactiveColor = 'lyrics_view_inactive_color';
  static const String _prefsViewActiveColor = 'lyrics_view_active_color';
  static const String _prefsViewHighlightColor = 'lyrics_view_highlight_color';

  final LyricsRepository _repo = LyricsRepository();
  final FnPlayerService _player = FnPlayerService.instance;
  final AppPlayerState _state = AppPlayerState.instance;
  final LyricController controller = LyricController();
  final ValueNotifier<LyricsSnapshot> snapshot = ValueNotifier(
    LyricsSnapshot.idle(),
  );
  final ValueNotifier<String?> currentLineText = ValueNotifier(null);
  final ValueNotifier<int> viewSettingsTick = ValueNotifier(0);

  /// 当前这份歌词的来历。
  ///
  /// `null` 表示**来自音乐库**（音乐库缓存或音乐库接口都算）；非空表示是联网
  /// 刮来的，里面的渠道 id 与「渠道侧配到了谁的版本」可以直接显示给用户。
  /// 这个区分以前只存在于 debug 日志里，用户无从判断屏幕上的词是哪来的。
  final ValueNotifier<LyricOrigin?> currentOrigin = ValueNotifier(null);

  /// 歌词页自定义颜色的镜像，供播放页逐字歌词保持一致。
  final ValueNotifier<int?> viewInactiveColor = ValueNotifier(null);
  final ValueNotifier<int?> viewActiveColor = ValueNotifier(null);
  final ValueNotifier<int?> viewHighlightColor = ValueNotifier(null);
  late final snapshotSignal = signal(LyricsSnapshot.idle());
  late final viewSettingsTickSignal = signal(0);
  late final activeIndexSignal = signal(controller.activeIndexNotifiter.value);
  late final lyricModelSignal = signal(controller.lyricNotifier.value);
  late final isSelectingSignal = signal(controller.isSelectingNotifier.value);
  late final selectedIndexSignal = signal(
    controller.selectedIndexNotifier.value,
  );

  int _loadSeq = 0;
  bool _viewForceKaraoke = false;

  LyricsService._internal() {
    snapshot.addListener(() => snapshotSignal.value = snapshot.value);
    viewSettingsTick.addListener(
      () => viewSettingsTickSignal.value = viewSettingsTick.value,
    );
    controller.activeIndexNotifiter.addListener(
      () => activeIndexSignal.value = controller.activeIndexNotifiter.value,
    );
    controller.activeIndexNotifiter.addListener(_onActiveIndexChanged);
    controller.lyricNotifier.addListener(
      () => lyricModelSignal.value = controller.lyricNotifier.value,
    );
    controller.isSelectingNotifier.addListener(
      () => isSelectingSignal.value = controller.isSelectingNotifier.value,
    );
    controller.selectedIndexNotifier.addListener(
      () => selectedIndexSignal.value = controller.selectedIndexNotifier.value,
    );
    controller.setOnTapLineCallback((pos) {
      controller.stopSelection();
      _player.seek(pos);
    });
    _state.currentSong.addListener(_onSongChanged);
    _state.position.addListener(_onPositionChanged);
    _state.isPlaying.addListener(_onPlayingChanged);
    viewSettingsTick.addListener(_reloadViewColorPrefs);
    refreshSettings();
    _reloadViewColorPrefs();
    _onSongChanged();
  }

  void notifyViewSettingsChanged() {
    viewSettingsTick.value = viewSettingsTick.value + 1;
  }

  Future<void> _reloadViewColorPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    viewInactiveColor.value = prefs.getInt(_prefsViewInactiveColor);
    viewActiveColor.value = prefs.getInt(_prefsViewActiveColor);
    viewHighlightColor.value = prefs.getInt(_prefsViewHighlightColor);
  }

  Future<void> refreshSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _viewForceKaraoke = prefs.getBool(_prefsViewForceKaraoke) ?? false;
  }

  /// 是否强制逐字卡拉OK（当前行按字高亮）。
  bool get forceKaraoke => _viewForceKaraoke;

  /// 当前歌词来源的显示文案；`null` 表示来自音乐库。
  ///
  /// 放在服务层而不是界面层，是因为「渠道 id → 人看的名字」这个映射归
  /// [OnlineLyricSource] 管（源列表在它那里），界面不该自己维护一份。
  String? get currentSourceLabel {
    final origin = currentOrigin.value;
    if (origin == null) return null;
    return OnlineLyricSource.instance.displayNameFor(origin.sourceId);
  }

  void _onSongChanged() {
    final song = _state.currentSong.value;
    _loadForSong(song);
  }

  void _onPositionChanged() {
    controller.setProgress(_state.position.value);
  }

  void _onPlayingChanged() {
    // 播放状态影响歌词自动滚动暂停/恢复，由 LyricView 内部处理。
  }

  void _onActiveIndexChanged() {
    _updateCurrentLineText(controller.activeIndexNotifiter.value);
  }

  void reloadCurrentSong() {
    _loadForSong(_state.currentSong.value);
  }

  /// 重新匹配当前这首歌的歌词。
  ///
  /// 与 [reloadCurrentSong] 的区别很重要：后者是「拿现有缓存重新解析一遍」，
  /// 用在改了渲染参数（例如刚打开强制逐字）的时候；这里是**「我不认可现在
  /// 这份词，请重新去找」** —— 所以要先删掉这首歌的两层缓存、失败记忆与来源
  /// 记录，再完整走一遍四步流程。
  ///
  /// 为什么需要它：这个曲库的歌词**全部靠跨歌手采纳**（曲库里的歌手是翻唱者，
  /// 歌词库里只有原唱条目），判据是「歌名一致 + 时长贴合」，所以「配到别的版本」
  /// 是必然会发生的。而原来一旦配错，用户除了清空**全部**歌词缓存之外没有任何
  /// 办法 —— 连「这首歌配错了」都无从表达。
  Future<void> rematchCurrentSong() async {
    final song = _state.currentSong.value;
    if (song == null) return;
    await _repo.removeCachedLrc(song.guid);
    await OnlineLyricSource.instance.clearMissFor(song.guid);
    await LyricOriginStore.instance.remove(song.guid);
    // 清缓存是异步的，期间用户可能已经切歌；切了就不要再往回拉。
    if (_state.currentSong.value?.guid != song.guid) return;
    await _loadForSong(song);
  }

  /// 曲库这首歌与渠道侧命中歌曲的时长差（绝对值，毫秒）。
  ///
  /// 这个曲库的歌词全部靠跨歌手采纳，所以时长差是判断「配上的到底是不是这一版」
  /// 的核心线索：差得越多，时间轴越可能对不上。
  static int? _durationDeltaMs(int? songDurationMs, int? matchedDurationMs) {
    if (songDurationMs == null || matchedDurationMs == null) return null;
    return (songDurationMs - matchedDurationMs).abs();
  }

  Future<void> _loadForSong(SongEntity? song) async {
    final seq = ++_loadSeq;
    snapshot.value = snapshot.value.copyWith(
      status: LyricsLoadStatus.loading,
      song: song,
      model: null,
      error: null,
    );
    controller.lyricNotifier.value = null;
    currentLineText.value = null;
    currentOrigin.value = null;

    if (song == null) {
      snapshot.value = snapshot.value.copyWith(
        status: LyricsLoadStatus.empty,
        song: null,
        model: null,
        error: null,
      );
      return;
    }

    try {
      await refreshSettings();

      // 四步按优先级找词，**音乐库永远优先**：
      //   1. 音乐库歌词的本地缓存
      //   2. 音乐库接口
      //   3. 在线歌词的本地缓存（刮到过一次就不再联网，省接口配额也省等待）
      //   4. 在线多源兜底
      //
      // 要点是 1/2 与 3/4 落在**不同的缓存文件**里（见 [LyricsCacheLayer]）。
      // 早先两者共用一个文件，而读取是「命中就返回」，于是先落地的在线歌词会把
      // 音乐库后来补的歌词永久挡住 —— 曲库里补了正式歌词也看不见。
      String? lrc = await _repo.loadNasLrc(song.guid);
      if (seq != _loadSeq) return;

      if (lrc == null || lrc.trim().isEmpty) {
        lrc = await _repo.fetchFromNas(song);
        if (seq != _loadSeq) return;
      }

      LyricOrigin? origin;

      if (lrc == null || lrc.trim().isEmpty) {
        lrc = await _repo.loadOnlineLrc(song.guid);
        if (seq != _loadSeq) return;
        if (lrc != null && lrc.trim().isNotEmpty) {
          // 缓存里已有刮来的词，把它的来历一并取出来显示。
          origin = await LyricOriginStore.instance.get(song.guid);
        }
      }

      if (lrc == null || lrc.trim().isEmpty) {
        // 音乐库与在线缓存都没有 → 走多源兜底（源顺序、350ms 节流、限流冷却、
        // 失败记忆都在 OnlineLyricSource 内部处理）。
        final online = await OnlineLyricSource.instance.fetchForSong(song);
        if (seq != _loadSeq) return;
        if (online != null && online.content.trim().isNotEmpty) {
          await _repo.saveOnlineLrc(song.guid, online.content);
          lrc = online.content;
          origin = LyricOrigin(
            sourceId: online.sourceId,
            at: DateTime.now(),
            matchedTitle: online.matchedTitle,
            matchedArtist: online.matchedArtist,
            matchedDurationMs: online.matchedDurationMs,
            deltaMs: _durationDeltaMs(song.durationMs, online.matchedDurationMs),
            format: online.format.name,
          );
          await LyricOriginStore.instance.put(song.guid, origin);
          if (kDebugMode) {
            debugPrint(
              '[Lyrics] 在线补词: ${song.title} <- ${online.sourceId} '
              '(${online.format.name})',
            );
          }
        }
      }

      currentOrigin.value = origin;

      if (lrc == null || lrc.trim().isEmpty) {
        snapshot.value = snapshot.value.copyWith(
          status: LyricsLoadStatus.empty,
          song: song,
          model: null,
          error: null,
        );
        return;
      }

      final model = LyricsParser.buildModelFromRaw(
        lrc,
        songDuration: (song.durationMs == null)
            ? null
            : Duration(milliseconds: song.durationMs!),
        predictDuration: false,
        forceKaraoke: _viewForceKaraoke,
      );
      if (kDebugMode) {
        final translationCount = model.lines
            .where((line) => (line.translation ?? '').trim().isNotEmpty)
            .length;
        debugPrint(
          '[Lyrics] parsed ${model.lines.length} lines, '
          '$translationCount translations for ${song.title}',
        );
      }
      controller.loadLyricModel(model);
      _updateCurrentLineText(controller.activeIndexNotifiter.value);
      snapshot.value = snapshot.value.copyWith(
        status: LyricsLoadStatus.loaded,
        song: song,
        model: model,
        error: null,
      );
    } catch (e) {
      if (seq != _loadSeq) return;
      snapshot.value = snapshot.value.copyWith(
        status: LyricsLoadStatus.failed,
        song: song,
        model: null,
        error: e,
      );
    }
  }

  void _updateCurrentLineText(int index) {
    final model = controller.lyricNotifier.value;
    if (model == null || model.lines.isEmpty) {
      currentLineText.value = null;
      return;
    }
    if (index < 0 || index >= model.lines.length) {
      currentLineText.value = null;
      return;
    }
    final text = model.lines[index].text.trim();
    currentLineText.value = text.isEmpty ? null : text;
  }

  // ---------------------------------------------------------------------
  // 歌词样式设置（歌词设置页接线）
  // ---------------------------------------------------------------------

  /// 设置强制逐字卡拉OK（当前行按字高亮）。
  Future<void> setForceKaraoke(bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsViewForceKaraoke, value);
    await refreshSettings();
    notifyViewSettingsChanged();
  }

  /// 设置自定义歌词配色。任一为 null 表示不改动该项。
  Future<void> setViewColors({
    int? inactive,
    int? active,
    int? highlight,
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (inactive != null) {
      await prefs.setInt(_prefsViewInactiveColor, inactive);
    }
    if (active != null) {
      await prefs.setInt(_prefsViewActiveColor, active);
    }
    if (highlight != null) {
      await prefs.setInt(_prefsViewHighlightColor, highlight);
    }
    await _reloadViewColorPrefs();
    notifyViewSettingsChanged();
  }

  /// 清除自定义歌词配色，恢复跟随主题。
  Future<void> clearViewColors() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsViewInactiveColor);
    await prefs.remove(_prefsViewActiveColor);
    await prefs.remove(_prefsViewHighlightColor);
    await _reloadViewColorPrefs();
    notifyViewSettingsChanged();
  }
}
