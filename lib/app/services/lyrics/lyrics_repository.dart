import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../state/song_state.dart';
import '../feiniu/api_client.dart';

/// 歌词缓存的**来源分层**。
///
/// 历史教训：在线刮到的歌词与音乐库自带的歌词原先写进**同一个**文件，而读取
/// 是「缓存优先、命中即返回」，于是先落地的那一份会把后来的永久挡住 ——
/// 曲库里后来补了正式歌词也看不见，除非清空全部歌词缓存。
///
/// 现在按来源分成两个目录：
/// - [nas]    —— 从音乐库接口取到的，**读取优先级更高**
/// - [online] —— 联网刮到的兜底，只在音乐库没有时才用
///
/// 目录名同时是排查线索：`lyrics/nas/` 里有几个文件，就说明这首库有多少词是
/// 音乐库自带的；`lyrics/online/` 里的则是我们补的。
enum LyricsCacheLayer {
  nas,
  online;

  /// 缓存的子目录名。
  String get dirName => name;
}

class LyricsRepository {
  /// 歌词缓存根目录。历史版本把两种来源的 `.lrc` 直接平铺在这里，
  /// 现在下面分成 `nas/` 与 `online/` 两个子目录（见 [LyricsCacheLayer]）。
  static const String _rootDirName = 'lyrics';

  /// 测试注入点：替换「应用支持目录」，避免单测依赖 path_provider 插件。
  @visibleForTesting
  static String? supportDirOverride;

  bool _migrated = false;

  // ------------------------------------------------------------------
  // 读取
  // ------------------------------------------------------------------

  /// 读音乐库自带的歌词。
  Future<String?> loadNasLrc(String songGuid) async {
    await _ensureMigrated();
    return _readFromCache(songGuid, LyricsCacheLayer.nas);
  }

  /// 读联网刮到的歌词。
  Future<String?> loadOnlineLrc(String songGuid) async {
    await _ensureMigrated();
    return _readFromCache(songGuid, LyricsCacheLayer.online);
  }

  /// 读指定层级的缓存。
  Future<String?> loadCachedLrc(
    String songGuid, {
    required LyricsCacheLayer layer,
  }) async {
    await _ensureMigrated();
    return _readFromCache(songGuid, layer);
  }

  Future<bool> hasCachedLrc(String songGuid) async {
    await _ensureMigrated();
    return await _exists(songGuid, LyricsCacheLayer.nas) ||
        await _exists(songGuid, LyricsCacheLayer.online);
  }

  /// 从音乐库接口取歌词；取到就落到 [LyricsCacheLayer.nas]。
  ///
  /// 网络/接口失败一律静默返回 `null`，与原有行为一致 —— 歌词取不到不该打断播放。
  Future<String?> fetchFromNas(SongEntity song) async {
    await _ensureMigrated();
    try {
      final lyricText = await ApiClient.instance.getLyricText(song.guid);
      if (lyricText != null && lyricText.trim().isNotEmpty) {
        await _writeToCache(song.guid, lyricText, LyricsCacheLayer.nas);
        return lyricText;
      }
    } catch (_) {
      // 接口返回失败时静默处理。
    }
    return null;
  }

  // ------------------------------------------------------------------
  // 写入 / 清除
  // ------------------------------------------------------------------

  Future<void> saveNasLrc(
    String songGuid,
    String content, {
    bool overwrite = false,
  }) =>
      _save(songGuid, content, LyricsCacheLayer.nas, overwrite: overwrite);

  Future<void> saveOnlineLrc(
    String songGuid,
    String content, {
    bool overwrite = false,
  }) =>
      _save(songGuid, content, LyricsCacheLayer.online, overwrite: overwrite);

  /// 删掉这首歌的缓存。不指定 [layer] 时**两层都删**。
  Future<void> removeCachedLrc(
    String songGuid, {
    LyricsCacheLayer? layer,
  }) async {
    await _ensureMigrated();
    final layers = layer == null ? LyricsCacheLayer.values : <LyricsCacheLayer>[layer];
    for (final l in layers) {
      try {
        final file = await _cacheFileForSongId(songGuid, l);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------------
  // 整层维护（缓存管理页用）
  // ------------------------------------------------------------------

  Future<Directory> directoryFor(LyricsCacheLayer layer) async {
    final String support = await _supportDirPath();
    return Directory(p.join(support, _rootDirName, layer.dirName));
  }

  /// 应用支持目录。测试里用 [supportDirOverride] 顶掉 path_provider。
  Future<String> _supportDirPath() async {
    final override = supportDirOverride;
    if (override != null) return override;
    final Directory dir = await getApplicationSupportDirectory();
    return dir.path;
  }

  /// 某一层的占用字节数。
  Future<int> layerSize(LyricsCacheLayer layer) async {
    await _ensureMigrated();
    try {
      final dir = await directoryFor(layer);
      if (!await dir.exists()) return 0;
      int total = 0;
      await for (final FileSystemEntity f
          in dir.list(recursive: true, followLinks: false)) {
        if (f is File) total += await f.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清空某一层（保留目录本身，避免后续写缓存报错）。
  Future<void> clearLayer(LyricsCacheLayer layer) async {
    await _ensureMigrated();
    try {
      final dir = await directoryFor(layer);
      if (!await dir.exists()) return;
      await for (final FileSystemEntity e in dir.list(followLinks: false)) {
        await e.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// 某一层里有多少份歌词 —— 直接对应「有多少首歌的词来自这里」。
  ///
  /// 只数 `.lrc`：在线层里还放着来源记录等非歌词文件，不能算成歌词。
  Future<int> layerFileCount(LyricsCacheLayer layer) async {
    await _ensureMigrated();
    try {
      final dir = await directoryFor(layer);
      if (!await dir.exists()) return 0;
      int n = 0;
      await for (final FileSystemEntity f
          in dir.list(recursive: true, followLinks: false)) {
        if (f is File && f.path.toLowerCase().endsWith('.lrc')) n++;
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  // ------------------------------------------------------------------
  // 内部
  // ------------------------------------------------------------------

  Future<void> _save(
    String songGuid,
    String content,
    LyricsCacheLayer layer, {
    required bool overwrite,
  }) async {
    await _ensureMigrated();
    final c = content.replaceFirst('﻿', '').trim();
    if (c.isEmpty) return;
    if (!overwrite) {
      final exists = await _exists(songGuid, layer);
      if (exists) return;
    }
    await _writeToCache(songGuid, c, layer);
  }

  Future<bool> _exists(String songGuid, LyricsCacheLayer layer) async {
    try {
      final file = await _cacheFileForSongId(songGuid, layer);
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  Future<String?> _readFromCache(
    String songId,
    LyricsCacheLayer layer,
  ) async {
    try {
      final file = await _cacheFileForSongId(songId, layer);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeToCache(
    String songId,
    String content,
    LyricsCacheLayer layer,
  ) async {
    try {
      final file = await _cacheFileForSongId(songId, layer);
      await file.parent.create(recursive: true);
      await file.writeAsString(content, flush: true);
    } catch (_) {}
  }

  Future<File> _cacheFileForSongId(String songId, LyricsCacheLayer layer) async {
    final Directory dir = await directoryFor(layer);
    return File(p.join(dir.path, '${_cacheKey(songId)}.lrc'));
  }

  /// 一次性迁移：历史版本把两种来源都写在 `lyrics/<hash>.lrc`。
  ///
  /// 为什么整体归入 [LyricsCacheLayer.online]：本曲库实测**音乐库自带歌词 0 首**
  /// （见《随机 50 首实测报告》），旧扁平文件几乎全是在线刮出来的。万一某个文件
  /// 其实是音乐库歌词，下次播放会重新从接口取一遍并落到 `nas/`，结果依然正确，
  /// 代价只是多一次请求 —— 比「把在线歌词误当成音乐库歌词从而永远压住真正的词」
  /// 安全得多。
  ///
  /// 用 rename 而不是 copy：迁移是搬走，不留旧副本，否则清缓存会漏掉一半。
  Future<void> _ensureMigrated() async {
    if (_migrated) return;
    _migrated = true;
    try {
      final String support = await _supportDirPath();
      final Directory legacy = Directory(p.join(support, _rootDirName));
      if (!await legacy.exists()) return;

      final Directory target = Directory(
        p.join(support, _rootDirName, LyricsCacheLayer.online.dirName),
      );
      await target.create(recursive: true);

      await for (final FileSystemEntity e in legacy.list(followLinks: false)) {
        if (e is! File || !e.path.toLowerCase().endsWith('.lrc')) continue;
        final dest = File(p.join(target.path, p.basename(e.path)));
        if (await dest.exists()) {
          await e.delete();
          continue;
        }
        try {
          await e.rename(dest.path);
        } catch (_) {
          // 跨卷 rename 可能失败，退化为读+写。
          try {
            await dest.writeAsBytes(await e.readAsBytes(), flush: true);
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {
      // 迁移失败不影响功能：旧文件仍在，只是这一轮读不到而已。
    }
  }

  /// FNV-1a 64 位散列，避免曲目 guid 直接落在文件名里。
  String _cacheKey(String songId) {
    final bytes = utf8.encode(songId);
    const int offsetBasis = 0xcbf29ce484222325;
    const int prime = 0x100000001b3;
    const int mask64 = 0xFFFFFFFFFFFFFFFF;
    var hash = offsetBasis;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * prime) & mask64;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }
}
