package com.fnmusic.app

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val downloadsChannelName = "com.fnmusic.app/downloads"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyOrientationPolicy(resources.configuration)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        applyOrientationPolicy(newConfig)
    }

    /// 屏幕方向策略 —— 小米《大屏适配技术指南》2.2 节官方推荐逻辑：
    ///
    /// - 窗口长宽比 > 16:9（手机等竖长窗口）→ 锁竖屏。手机上不随重力
    ///   旋转，杜绝「拿着手机歪一下界面就横过来」。
    /// - 窗口长宽比 ≤ 16:9（平板横屏、车机 2/3 与全屏窗口）→ 不锁定。
    ///   Pin 到小米车机后应用窗口是横宽的（妙享桌面柔性窗口），必须允许
    ///   横屏，Flutter 侧的横屏分栏布局才能生效；1/3 窗口是竖长的
    ///   （约 480×900dp），自动落回竖屏堆叠布局。
    ///
    /// 判据用**窗口**尺寸而非屏幕尺寸：多窗口/投屏场景两者不等价
    /// （见技术指南 2.1：布局必须以窗口大小为准）。
    private fun applyOrientationPolicy(config: Configuration) {
        val longSide = maxOf(config.screenWidthDp, config.screenHeightDp).toFloat()
        val shortSide = minOf(config.screenWidthDp, config.screenHeightDp).toFloat()
        val isTallRatio = longSide / shortSide > 16f / 9f
        requestedOrientation = if (isTallRatio) {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        } else {
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Android 平台能力查询。P6 只用 getAndroidSdkInt（通知自定义按钮
        // 能力探测）；后续阶段扩展下载、投屏、悬浮窗等 Channel 时在此追加。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            downloadsChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAndroidSdkInt" -> {
                    result.success(Build.VERSION.SDK_INT)
                }
                else -> result.notImplemented()
            }
        }

    }
}
