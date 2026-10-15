import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名配置。密码与密钥路径放在 android/key.properties（已被 .gitignore 忽略，
// 千万不要提交）。该文件缺失时（例如他人 clone 本仓库）自动退回 debug 签名，
// 保证任何人都还能直接把项目构建出来。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.fnmusic.app"
    // Flutter 3.47 插件生态（connectivity_plus/dynamic_color 等）要求 compileSdk 36；
    // minSdk/targetSdk 仍为 35（Android 15+）。
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // 开启 core library desugaring（参考项目同款配置）
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.fnmusic.app"
        // 仅支持 Android 15+（API 35）
        minSdk = 35
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // 有 key.properties 时用正式签名；缺失则退回 debug 签名。
            // 注意：签名一旦对外发布就不能再换，否则已安装的用户只能卸载重装。
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 与参考项目一致：关闭 R8/资源压缩（体积主要由原生库构成）
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Shizuku（灵动岛焦点通知白名单绕过）
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
}
