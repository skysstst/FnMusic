/// 歌词文本格式工具：判定、清洗与「逐字格式 → 增强型 LRC」转换。
///
/// 为什么一律转成增强型 LRC（Enhanced LRC）：
/// FnMusic 现有的 `LyricsParser.buildModelFromRaw()` 只认两种输入 ——
/// 1. 普通 LRC：`[mm:ss.xxx]整行文本`
/// 2. **行内交错时间戳**：`[t1]字[t2]字[t3]字…`（且一行内时间戳数 ≥ 3 时，
///    会被解析成带 `words` 的逐字行）
///
/// 所以只要把任何逐字源（YRC / QRC / AMLL 的 .eslrc）统一成第 2 种格式，
/// 渲染层（卡拉OK 逐字高亮、拖动跳转）**一行代码都不用改**。
class LrcFormats {
  const LrcFormats._();

  static final RegExp _timestamp = RegExp(r'\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]');
  static final RegExp _metaLine = RegExp(
    r'^\[(ti|ar|al|by|offset|re|ve|length|kana):',
    caseSensitive: false,
  );

  /// 单行内的时间戳数量。
  static int timestampCount(String line) => _timestamp.allMatches(line).length;

  /// 文本是否为「行内交错时间戳」的增强型 LRC。
  ///
  /// 判定用的是与解析器**同一套**条件：只要存在一行时间戳数量 ≥ 3，
  /// 解析器就会走逐字分支。用同样的阈值可以避免「我们以为给了逐字、
  /// 实际被当成整行」这种静默降级。
  static bool isWordSynced(String text) {
    for (final line in text.split(RegExp(r'\r?\n'))) {
      if (line.trim().isEmpty) continue;
      if (timestampCount(line) >= 3) return true;
    }
    return false;
  }

  /// 是否含有至少一行可解析的时间轴歌词。
  static bool hasSyncedLines(String text) {
    for (final line in text.split(RegExp(r'\r?\n'))) {
      if (_timestamp.hasMatch(line)) return true;
    }
    return false;
  }

  /// 去掉接口可能混入的非 LRC 内容：
  /// - 网易云 `lyric/v1` 的富文本行（以 `{` 开头的 JSON）
  /// - 注释行（`//`、`/*`、`<!`）
  /// 保留 `[ti:…]` 这类元信息与正常歌词行。
  static String sanitize(String raw) {
    final out = <String>[];
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('{')) continue;
      if (t.startsWith('//') || t.startsWith('/*') || t.startsWith('<!')) {
        continue;
      }
      out.add(line);
    }
    return out.join('\n');
  }

  /// 把「翻译」按时间戳并进原文，输出为 `原文 / 译文` 单行。
  ///
  /// 走单行内联而不是「同一时间戳两行」，是因为 FnMusic 的
  /// `LyricsParser._splitTranslation()` 已经会识别 ` / ` 分隔符并拆成
  /// 原文 + 翻译，不需要依赖「同时刻两行」的合并逻辑。
  static String mergeTranslation(String main, String? translation) {
    if (translation == null || translation.trim().isEmpty) {
      return sanitize(main);
    }
    final transMap = <int, String>{};
    for (final line in translation.split(RegExp(r'\r?\n'))) {
      final m = _timestamp.firstMatch(line);
      if (m == null) continue;
      final text = line.replaceAll(_timestamp, '').trim();
      if (text.isEmpty) continue;
      transMap[_matchToMs(m)] = text;
    }
    if (transMap.isEmpty) return sanitize(main);

    final out = <String>[];
    for (final line in main.split(RegExp(r'\r?\n'))) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final m = _timestamp.firstMatch(t);
      if (m == null) {
        out.add(line);
        continue;
      }
      if (_metaLine.hasMatch(t)) {
        out.add(line);
        continue;
      }
      final text = t.replaceAll(_timestamp, '').trim();
      final trans = transMap[_matchToMs(m)];
      if (text.isEmpty || trans == null) {
        out.add(line);
        continue;
      }
      // 原文里若已自带内联译文，就不再叠加。
      if (text.contains(' / ')) {
        out.add(line);
        continue;
      }
      out.add('${_timestamp.allMatches(t).map((e) => e.group(0)).join()}'
          '$text / $trans');
    }
    return out.join('\n');
  }

  /// 网易云 YRC → 增强型 LRC。
  ///
  /// 输入样例：
  /// `[29231,3492](29231,461,0)故(29692,365,0)事(30057,415,0)的…`
  static String yrcToEnhanced(String yrc) {
    return _convertPerWord(
      yrc,
      lineHead: RegExp(r'^\[(\d+),(\d+)\]'),
      word: RegExp(r'\((\d+),(\d+),\d+\)([^()]*)'),
    );
  }

  /// QQ 音乐 QRC → 增强型 LRC。
  ///
  /// 输入样例：
  /// `[29231,3492]故(29231,461)事(29692,365)的(30057,415)…`
  static String qrcToEnhanced(String qrc) {
    return _convertPerWord(
      qrc,
      lineHead: RegExp(r'^\[(\d+),(\d+)\]'),
      word: RegExp(r'([^()\[\]]+?)\((\d+),(\d+)\)'),
    );
  }

  static String _convertPerWord(
    String raw, {
    required RegExp lineHead,
    required RegExp word,
  }) {
    final out = <String>[];
    for (final source in raw.split(RegExp(r'\r?\n'))) {
      final line = source.trim();
      if (line.isEmpty) continue;
      final head = lineHead.firstMatch(line);
      if (head == null) continue;
      final lineStart = int.parse(head.group(1)!);
      final lineDuration = int.parse(head.group(2)!);

      final parts = <String>[];
      final starts = <int>[];
      for (final m in word.allMatches(line.substring(head.end))) {
        // YRC 的分组是 (start,dur,text)，QRC 是 (text,start,dur)，两者分组数量
        // 都是 3 —— 所以用「第 1 组能否解析成整数」判别，按分组数量判别会误伤 QRC。
        final g1 = m.group(1)!;
        final g2 = m.group(2)!;
        final g1AsNumber = int.tryParse(g1);
        final int startMs;
        final String text;
        if (g1AsNumber != null) {
          startMs = g1AsNumber;
          text = m.group(3) ?? '';
        } else {
          text = g1;
          startMs = int.tryParse(g2) ?? -1;
        }
        final trimmed = text.trim();
        if (startMs < 0 || trimmed.isEmpty) continue;
        parts.add(trimmed);
        starts.add(startMs);
      }
      if (parts.isEmpty) continue;

      final buf = StringBuffer();
      for (var i = 0; i < parts.length; i++) {
        buf.write('[${LyricTimestamp.format(starts[i])}]${parts[i]}');
      }
      // 收尾时间戳：让最后一段有明确的结束点，否则解析器会把「下一行开始」
      // 当成它的结束，导致最后一个字一直高亮到下一行。
      buf.write('[${LyricTimestamp.format(lineStart + lineDuration)}]');
      out.add(buf.toString());
    }
    return out.join('\n');
  }

  static int _matchToMs(RegExpMatch m) {
    final mm = int.tryParse(m.group(1) ?? '0') ?? 0;
    final ss = int.tryParse(m.group(2) ?? '0') ?? 0;
    final frac = m.group(3);
    var ms = 0;
    if (frac != null) {
      ms = int.tryParse(frac.padRight(3, '0').substring(0, 3)) ?? 0;
    }
    return mm * 60 * 1000 + ss * 1000 + ms;
  }
}

/// 时间戳格式化（与 `LyricTextNorm.formatTimestamp` 同源，单独放一份避免循环依赖）。
class LyricTimestamp {
  const LyricTimestamp._();

  static String format(int ms) {
    if (ms < 0) ms = 0;
    final totalSeconds = ms ~/ 1000;
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    final millis = ms % 1000;
    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}';
  }
}
