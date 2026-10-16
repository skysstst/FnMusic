import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app.dart';
import 'app/services/backup/backup_service.dart';
import 'app/services/feiniu/auth_service.dart';
import 'app/services/listening_recorder_service.dart';
import 'app/services/media_notification_service.dart';
import 'app/services/player_service.dart';
import 'app/services/stats_service.dart';
import 'app/state/player_state.dart';
import 'app/state/settings_state.dart';

void _onPlayerSnapshot() {
  final PlayerSnapshot snap = AppPlayerState.instance.snapshot.value;
  // 听歌统计（song_stats / listening_days）与行为流水（report_events）。
  StatsService.instance.onSnapshot(snap);
  ListeningRecorderService.instance.onSnapshot(snap);
}

class _LifecycleFlushObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      // 退到后台：把未落库的收听累计与行为会话写盘。
      unawaited(StatsService.instance.flush());
      unawaited(ListeningRecorderService.instance.onLifecyclePause());
    }
  }
}

/// 进程级 SSL 证书校验覆盖。
///
/// 通过 [HttpOverrides.global] 安装，拦截进程内所有 [HttpClient]
/// （Dio 默认适配器、探测 Dio、CachedNetworkImage 等）。
/// [badCertificateCallback] 实时读取 [AppFnConnectionSettings.ignoreSsl]，
/// 开关动态度生效，无需重启 APP。默认开启以兼容自签名证书 /
/// 企业网关重签（Sangfor 等）的环境。
class _SslOverride extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (_, _, _) =>
        AppFnConnectionSettings.ignoreSsl.value;
    return client;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 进程级 SSL 覆盖：必须先于任何网络请求安装（读取 ignoreSsl 偏好）。
  HttpOverrides.global = _SslOverride();

  // Android 15 强制 edge-to-edge。
  // 这行在旧引擎/某些 ROM 上可能挂住（平台通道无回执），同样限时。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge).timeout(
        const Duration(seconds: 5),
        onTimeout: () => debugPrint('[main] setEnabledSystemUIMode 超时，跳过'),
      );

  // 加载全部设置域（主题 / 引导状态等）。读 SharedPreferences，
  // 但插件初始化异常时 Future 可能永不完成 —— 限时兜底。
  await SettingsState.loadAll().timeout(
        const Duration(seconds: 8),
        onTimeout: () => debugPrint('[main] 设置加载超时，用默认值继续'),
      );

  // 先恢复已保存账号的会话（幂等）：只有登录后才配置 ApiClient 的服务器
  // 地址与 token。播放器 init 内部的 restore() 需要 baseUrl 才能重建流，
  // 若顺序颠倒，持久化队列存在时会在 _buildAudioSource 抛「未配置服务器地址」。
  //
  // **这里必须限时**：`main()` 的 await 链是在 `runApp` **之前**执行的，
  // 所以下面任何一步挂住，用户看到的就是 Flutter 引擎自带的那个闪屏 ——
  // 不是我们的启动门（那还没被创建），也不是登录页，什么提示都没有，
  // 只能强杀。实测卡在中继握手 `restoreConnection` 上。
  // 兜底是「超时即视为离线、保留会话」：断网不该把人踢回登录页，
  // 后续请求本来都有各自的错误处理。
  await AuthService.instance.initialize().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          debugPrint('[main] 会话恢复超时，按离线继续');
        },
      );

  // 播放器：配置音频焦点 + 恢复上次播放状态。
  // 同样限时：恢复上次播放要去服务器问流地址，网络不通时不该拦住整个启动。
  await FnPlayerService.instance
      .init()
      .timeout(const Duration(seconds: 10), onTimeout: () {
    debugPrint('[main] 播放器初始化超时，跳过恢复');
  });

  // 媒体通知（MediaSession / 通知栏 / Android Auto / 车载歌词）。
  // 内部自行判断是否已有播放内容；没有则仅注册 MediaSession 供
  // Android Auto 发现，首次播放时再完成 handler 初始化。
  await MediaNotificationService.init().timeout(
        const Duration(seconds: 8),
        onTimeout: () => debugPrint('[main] 媒体通知初始化超时，跳过'),
      );

  // 听歌统计：订阅播放快照；退后台时兜底落库。
  AppPlayerState.instance.snapshot.addListener(_onPlayerSnapshot);
  WidgetsBinding.instance.addObserver(_LifecycleFlushObserver());

  // 自动备份：每天首次打开时向已配置的 WebDAV 目标上传（静默失败）。
  unawaited(BackupService.instance.maybeAutoBackupOnLaunch());

  runApp(const FnMusicApp());
}
