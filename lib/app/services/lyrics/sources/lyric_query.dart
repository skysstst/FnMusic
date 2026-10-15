import '../../../state/song_state.dart';
import 'trad_simp_table.dart';

/// 在线歌词匹配用的查询条件。
///
/// 各歌词源只认「歌名 + 歌手（+ 专辑 + 时长）」这几项，而 [SongEntity] 里给的
/// 是**展示用**字符串（`artistDisplay` / `albumDisplay` 可能带分隔符与括号补充），
/// 直接丢给接口匹配率很差，所以这里统一做一次归一化。
class LyricQuery {
  const LyricQuery({
    required this.title,
    required this.artist,
    this.album,
    this.durationMs,
  });

  /// 原始歌名（未归一化，发给接口用）。
  final String title;

  /// 主歌手（多歌手时取第一个，未归一化）。
  final String artist;

  /// 专辑名（可选）。
  final String? album;

  /// 歌曲时长（毫秒）。**这是最重要的校验维度**：LRCLIB 服务端只接受 ±2 秒
  /// 以内的记录，其余源也用它在多个候选里做筛选。
  final int? durationMs;

  factory LyricQuery.fromSong(SongEntity song) {
    // 先算歌手：标题清洗需要用它来剥掉拼进标题里的歌手名。
    final String artist = LyricTextNorm.primaryArtist(song.artistDisplay);
    return LyricQuery(
      title: LyricTextNorm.cleanTitle(song.title, artist: artist),
      artist: artist,
      album: (song.albumDisplay == null || song.albumDisplay!.trim().isEmpty)
          ? null
          : song.albumDisplay,
      durationMs: song.durationMs,
    );
  }

  /// 归一化后的比较键，用于本地相似度筛选（不含空格与标点、全角转半角、小写）。
  String get titleKey => LyricTextNorm.normalize(title);
  String get artistKey => LyricTextNorm.normalize(artist);
  String? get albumKey =>
      album == null ? null : LyricTextNorm.normalize(album!);

  @override
  String toString() =>
      'LyricQuery($title / $artist / ${album ?? '-'} / ${durationMs ?? '-'}ms)';
}

/// 歌词匹配专用的文本归一化工具。
///
/// 这里**不使用**正则去「智能」猜语义，只做可预期的确定性清洗，避免把小众歌名
/// （含括号、连字符、日文全角符号）改坏。
///
/// 规则全部来自对真实曲库 **11,425 首**歌名的形态统计（见改造方案报告），
/// 不是拍脑袋想出来的，改动前请先跑一遍统计。
class LyricTextNorm {
  const LyricTextNorm._();

  // ------------------------------------------------------------ 公共入口

  /// 把原始标题清洗成**一个**主查询词。猜不出来时原样返回，绝不乱切。
  ///
  /// 清洗顺序：
  /// 1. 全角转半角；
  /// 2. 去日期前缀（`16.12.15` / `20240106` / `220716` / `2024-01-06`）；
  /// 3. 去开头短方括号块（`【暗杠校园游】走歌人` → `走歌人`）；
  /// 4. 去版本说明括号（`(Live)` / `（现场版）` / `[KTV]`）；
  /// 5. 抹掉夹在汉字中间的间隔号（`但愿人长.久` → `但愿人长久`）；
  /// 6. 按分隔符切段，丢掉噪音段（见 [_stripSegmentNoise]）；
  /// 7. 去收尾的「（参与者）」备注、去表情符号。
  static String cleanTitle(String raw, {String? artist}) {
    // 繁转简要**放在最前**：曲库里 1,830 首的标题与歌手都是繁体（`陳一發兒`、
    // `淚橋`），而中文歌词库绝大多数条目存的是简体。带着繁体去搜不一定搜不到
    // （QQ 音乐能容错），但容错是概率问题——统一转简是把概率拉满。
    // 与 `tools/_normalize.py` 的 `clean_title` 同序，改一边记得改另一边。
    var s = toSimplified(toHalfWidth(raw.trim()));
    if (s.isEmpty) return '';

    s = s.replaceFirst(_datePrefix, '');
    s = _trimEdge(s);
    s = s.replaceFirst(_leadingBracket, '').trim();
    s = s.replaceAll(_versionParen, '').trim();
    s = s.replaceAll(_cjkDot, '').trim();
    // 尾部的「（参与者）」备注要在**切段之前**去掉：`杠姐家做客-茶汤（崩）`
    // 若不先去掉，尾段就不是纯汉字，头段的「短人名」判据会失效，整首只好原样保留。
    final String core = s.replaceFirst(_trailingNote, '').trim();
    if (core.isNotEmpty) s = core;
    if (s.isEmpty) return '';

    s = _stripSegmentNoise(s);

    s = s.replaceAll(_emoji, '').trim();
    return s;
  }

  // ------------------------------------------------------------ 基础工具

  /// 歌手字段里常见的“合作”标记。
  static final RegExp _feat = RegExp(
    r'\s*[\(\（\[\【]?\s*(?:feat\.?|ft\.?|featuring|with|合唱|/|、|,|，|&|＆|x|X)\s*'
    r'(?=[^\)\）]*)',
  );

  /// 全角 → 半角（仅 ASCII 可打印区间），避免全角括号、全角字母造成匹配失败。
  static String toHalfWidth(String s) {
    final buf = StringBuffer();
    for (final r in s.runes) {
      if (r == 0x3000) {
        buf.write(' ');
      } else if (r >= 0xFF01 && r <= 0xFF5E) {
        buf.writeCharCode(r - 0xFEE0);
      } else {
        buf.writeCharCode(r);
      }
    }
    return buf.toString();
  }

  /// 取主歌手：以常见分隔符切分后取第一段，并去掉 feat. 尾巴。
  static String primaryArtist(String? raw) {
    // 与 [cleanTitle] 同样先繁转简：曲库有 1,830 首的歌手字段写作 `陳一發兒`，
    // 而歌手会被拼进第二轮关键词（`歌名 + 歌手`）——两段简繁不一致会白丢一轮。
    final s = toSimplified(toHalfWidth((raw ?? '').trim()));
    if (s.isEmpty) return '';
    var first = s;
    for (final sep in const <String>['/', '、', ',', '，', '&', '＆', ';', '；']) {
      final idx = first.indexOf(sep);
      if (idx > 0) first = first.substring(0, idx);
    }
    first = first.replaceAll(_feat, '').trim();
    return first.isEmpty ? s : first;
  }

  // ------------------------------------------------------------ 正则与词表

  /// 名称后常见的「版本说明」括号，匹配时应当忽略。
  static final RegExp _versionParen = RegExp(
    r'\s*[\(\（\[\【]\s*(?:'
    r'live|remaster(?:ed)?|remix|acoustic|instrumental|demo|version|ver\.?|edit|'
    r'cover|ktv|mono|stereo|radio\s*edit|album\s*version|single\s*version|deluxe|'
    r'现场(?:版)?|重制(?:版)?|重置(?:版)?|录音室版|伴奏|纯音乐|翻唱|原唱|'
    r'高音质|无损|完整版|官方版|电视剧|电影|动画|片头曲|片尾曲|插曲|主题曲'
    r')\s*[\)\）\]\】]',
    caseSensitive: false,
  );

  /// 日期前缀。实测曲库里同时存在 `16.12.15`、`20240106`、`220716`、
  /// `2024-01-06` 四种写法，覆盖 1 万条以上，不清掉就一条都搜不到。
  static final RegExp _datePrefix = RegExp(
    r'^\s*(?:'
    r'\d{4}\s*[.\-/年]\s*\d{1,2}\s*[.\-/月]\s*\d{1,2}\s*日?'
    r'|\d{2}\s*[.\-/]\s*\d{1,2}\s*[.\-/]\s*\d{1,2}'
    r'|\d{8}'
    r'|\d{6}'
    r')\s*[.\-/－—–-]?\s*',
  );

  /// 开头的一个短方括号块：`【暗杠校园游】走歌人` → `走歌人`。
  static final RegExp _leadingBracket =
      RegExp(r'^\s*[\[【（(][^\]】）)]{1,10}[\]】）)]\s*');

  /// **两侧带空白**的横线（`歌名 - 歌手`）。与 [_dashLoose] 分开是核心判据。
  static final RegExp _dashSep = RegExp(r'\s+[-–—－]\s+');

  /// 任意横线（含全角）。
  static final RegExp _dashLoose = RegExp(r'[-–—－]');

  /// 纯汉字串。
  static final RegExp _pureCjk = RegExp(r'^[\u4e00-\u9fff]+$');

  /// 含任意汉字。给「拉丁歌手-歌名」那条规则当排除条件用。
  static final RegExp _hasCjk = RegExp(r'[\u4e00-\u9fff]');

  /// 夹在汉字中间的间隔号 / 句点：`但愿人长.久`。
  static final RegExp _cjkDot =
      RegExp(r'(?<=[\u4e00-\u9fff])[.。·・](?=[\u4e00-\u9fff])');

  /// 头段以歌手名开头但还挂了别的名字：`陈一发儿、暗杠-外面的世界`、
  /// `告一段落 - 陈一发儿 | 原创`。
  static final RegExp _artistHead =
      RegExp(r'^(?:陈一发儿|陳一發兒|陈一发|发姐)\s*[、,，/&＆+＋|｜:：]');

  /// 收尾的「（参与者）」备注，如 `飞鸟和蝉（一歌）`、`伤痕 (爆刘继芬)`。
  static final RegExp _trailingNote =
      RegExp(r'[\(\（]\s*[^\(\（\)\）]{1,12}\s*[\)\）]\s*$');

  /// 空白分隔的尾部人名：`淚橋 趙小臭` → `淚橋`。
  static final RegExp _spaceName =
      RegExp(r'^(?<head>.+?)\s+(?<tail>[\u4e00-\u9fff]{2,4})$');

  /// 表情符号 / 装饰字符。曲库里真有 `悟空🎸`、`同桌的你 🎸`，
  /// 歌词库标题里不会有它们，留在搜索词里只会降低召回。
  static final RegExp _emoji = RegExp(
    r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{2B00}-\u{2BFF}]',
    unicode: true,
  );

  /// 纯日期残段。
  static final RegExp _dateOnly = RegExp(r'^[\d\s.\-/年月日]+$');

  /// `01a`、`track 3` 这类轨道号残段。
  ///
  /// **必须要求带数字**：否则 `X-Ray` 的 `X` 会被当成轨道号，整首被切成 `Ray`。
  static final RegExp _trackNo =
      RegExp(r'^(?=[\d\s]*\d)[\d\s]*[a-zA-Z]{1,2}[\d\s]*$');

  /// 句读 / 语气词——出现说明这是一句「直播话题」而不是歌名。
  ///
  /// 由 [LyricEligibility] 复用，别再内联抄第二份。
  static final RegExp sentenceMark =
      RegExp(r'[，。！？、；：~～…]|吗|呢|吧|啊|哦|呀|哈');

  /// 曲库里明确认得出的「歌手段」。
  static const Set<String> _artistVocab = <String>{
    '陈一发儿', '陳一發兒', '陈一发', '发姐', '唱吧',
  };

  /// 事件 / 平台 / 场景词——出现即为「不是歌名」的段。
  static const Set<String> _eventVocab = <String>{
    '六周年茶话会', '五周年', '周年茶话会', '茶话会', '录音棚版', '直播',
    '电台', '歌友会', '生日会', '跨年', '春节', '翻唱', '唱吧', '全民k歌',
    'yy', 'b站', 'bilibili', '抖音',
  };

  /// 当前曲库的主播名。`cleanTitle` 之后标题里还留着它 → 是直播话题，不是歌。
  static final RegExp selfName = RegExp(r'陈一发|陳一發|发姐|发麻麻');

  /// 明显「不是单曲」的直播 / 播客关键词。
  static const List<String> broadcastWords = <String>[
    '茶话会', '连麦', '直播', '电台', '也播', '周报', '访谈', '聊天',
    '录播', '回放', '花絮', '彩蛋', '杂谈', '问答', '唱谈', '夜谈', '漫谈',
  ];

  /// 无人声 / 无词可刮。
  static const List<String> noLyricWords = <String>[
    '伴奏', '纯音乐', 'instrumental', 'off vocal', 'offvocal',
    '卡拉ok', 'karaoke', '静音', '无词',
  ];

  /// 清唱（用户明确说可以跳过）。
  static const List<String> acappellaWords = <String>[
    '清唱', '无伴奏', 'acapella', 'a cappella',
  ];

  /// 去掉首尾空白与分隔符残留（`2015.10.29 ` 清完会剩一个空格）。
  static String _trimEdge(String s) => s
      .replaceAll(RegExp(r'^[\s\-–—－.]+'), '')
      .replaceAll(RegExp(r'[\s\-–—－.]+$'), '');

  /// 某一段是不是「噪音」（歌手名 / 日期 / 栏目 / 轨道号）。
  ///
  /// **刻意不做「短段就当人名」的猜测**：本曲库里 `Lo-Fi`、`X-Ray`
  /// 都是正常歌名，按长度猜会把它们切坏。可用的确定性判据只有三个 ——
  /// 词表命中、头段带歌手名、纯日期/轨道号。
  static bool _isNoiseSegment(String seg) {
    final s = seg.trim();
    if (s.isEmpty) return true;
    final low = s.toLowerCase();
    if (_artistVocab.contains(s) || _artistVocab.contains(low)) return true;
    if (_artistHead.hasMatch(s)) return true;
    if (_eventVocab.contains(s) || _eventVocab.contains(low)) return true;
    if (_dateOnly.hasMatch(s)) return true;
    if (_trackNo.hasMatch(s)) return true;
    return false;
  }

  /// 丢掉标题里的噪音段。
  ///
  /// 形态统计（全库 11,425 条）给出的两条主力规则：
  /// - **不带空白**的 `-`：几乎都是「歌手-歌名」→ 取**尾段**。
  ///   实测 4,832 条 `陈一发儿-歌名` + 202 条 `王菲-当时的月亮` 全靠它。
  /// - **带空白**的 ` - `：几乎都是「歌名 - 歌手」→ 取**首段**
  ///   （`奇妙能力歌 - 陈一发儿`）。
  ///
  /// 两条形态都**只在恰好两段时才动**，而且**只在「一侧像噪音、另一侧不像」时才切**；
  /// 两边都像或都不像就原样保留 —— `Love - and - Peace` 这种本身有歧义，
  /// 一刀切会把整首搜成 `Love`，比不切更糟。
  ///
  /// 噪音段之外还有两条**纯形态推断**（词表认不全所有原唱，只能靠形状猜）：
  /// 头段是 2~6 字纯汉字、或头段是不含汉字的多词拉丁名 → 头段是歌手，取尾段。
  static String _stripSegmentNoise(String s) {
    final bool spaced = _dashSep.hasMatch(s);
    final RegExp sep = spaced ? _dashSep : _dashLoose;
    final List<String> parts = sep.hasMatch(s)
        ? s
            .split(sep)
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false)
        : const <String>[];

    if (parts.length == 2) {
      final String head = parts[0];
      final String tail = parts[1];
      final bool headNoise = _isNoiseSegment(head);
      final bool tailNoise = _isNoiseSegment(tail);
      if (headNoise && !tailNoise) return tail;
      if (tailNoise && !headNoise) return head;
      // 紧凑形态再加一条：两侧都是纯汉字、且头段只有 2~6 字 → 头段是人名
      //（实测 202 条 `王菲-当时的月亮`、`蔡幸娟-问情` 靠它，词表认不全所有原唱）。
      if (!spaced &&
          !headNoise &&
          !tailNoise &&
          _pureCjk.hasMatch(head) &&
          _pureCjk.hasMatch(tail) &&
          head.length >= 2 &&
          head.length <= 6) {
        return tail;
      }
      // 拉丁文歌手的同型形态：`Lana Del Rey-Young And Beautiful`。
      // 判据是**头段带空格且不含汉字**（即「名 + 姓」那种多词人名）。
      // 为什么必须卡「≥ 2 个词」：全库里单词头段的只有 13 条，其中
      // `Mad-World（修复）`、`Lonely-Christmas（修复）` 本身就是**歌名里的横线**，
      // 切了会搜成 `World` / `Christmas`，比不切更糟；而多词头段的 9 条
      // （`Adam Levine-lost star`、`Ellie Goulding-Your Song`…）全是歌手-歌名，
      // 零反例。宁可漏掉 `lenka-the show` 这种 2 条，也不赌单词头段。
      if (!spaced &&
          !headNoise &&
          !tailNoise &&
          !_hasCjk.hasMatch(head) &&
          head.contains(' ')) {
        return tail;
      }
      return s;
    }

    if (parts.length > 2) return s;

    // 没有分隔符：`淚橋 趙小臭` 这类「歌名 + 空格 + 人名」。
    final m = _spaceName.firstMatch(s);
    if (m != null) return m.namedGroup('head')!.trim();
    return s;
  }

  // ------------------------------------------------------------ 繁简

  /// 繁 → 简单字映射的惰性索引（码位 → 码位）。
  static Map<int, int>? _tsIndex;

  /// 建一次索引，之后 O(1) 查表。
  static Map<int, int> get _ts {
    final cached = _tsIndex;
    if (cached != null) return cached;
    final keys = tradSimpKeys.runes.toList(growable: false);
    final vals = tradSimpValues.runes.toList(growable: false);
    final n = keys.length < vals.length ? keys.length : vals.length;
    final map = <int, int>{};
    for (var i = 0; i < n; i++) {
      map[keys[i]] = vals[i];
    }
    _tsIndex = map;
    return map;
  }

  /// 繁体 → 简体（仅单字映射，多对一的歧义字原样保留）。
  ///
  /// 曲库用繁体、歌词库返回简体是中文歌最常见的失配来源：`阿婆說` / `阿婆说`
  /// 归一化后若仍不相等，整首会**静默搜不到词**（连日志都没有），所以这一步必须做。
  /// 映射表见 [tradSimpKeys] / [tradSimpValues]。
  static String toSimplified(String raw) {
    final table = _ts;
    final buf = StringBuffer();
    for (final r in raw.runes) {
      buf.writeCharCode(table[r] ?? r);
    }
    return buf.toString();
  }

  /// 严格归一化：半角化 + 繁转简 + 小写 + 去掉全部空白与常见标点。用于「相等」比较。
  static String normalize(String raw) {
    var s = toSimplified(toHalfWidth(raw)).toLowerCase();
    s = s.replaceAll(_versionParen, '');
    s = s.replaceAll(RegExp(r'[\s\u00A0\u3000]'), '');
    s = s.replaceAll(RegExp(r'''[!-/:-@\[-`{-~]'''), '');
    s = s.replaceAll(RegExp(r'[、。，．！？：「」『』（）【】…—～·]'), '');
    return s;
  }

  // ------------------------------------------------------------ 打分

  /// 跨歌手采纳时的时长容差（毫秒）。
  ///
  /// 这个曲库是**民间翻唱合集**：曲库里的「歌手」是翻唱者，而网易云 / QQ 里
  /// 只有原唱条目，歌手永远对不上；同时翻唱版的时长与主流发行版差十几秒很常见。
  /// 所以跨歌手采纳时不能沿用「歌手对得上」时的紧容差，改用
  /// **绝对下限 10 秒 + 相对 12%** 取较大者：短歌靠绝对值、长歌靠相对值。
  static int crossArtistToleranceMs(int? queryDurationMs) {
    if (queryDurationMs == null) return 60000;
    final relative = (queryDurationMs * 0.12).round();
    return relative > 10000 ? relative : 10000;
  }

  /// 候选打分：> 0 表示可采纳（越大越可信），0 表示否决。
  ///
  /// 设计取舍：**歌名是主判据，歌手降级为加分项，时长是兜底校验**。
  /// - 歌手对得上 → 按各源自己的紧容差 [durationToleranceMs] 放行；
  /// - 歌手对不上（翻唱库的常态）→ 必须「歌名完全一致 + 时长落在
  ///   [crossArtistToleranceMs] 内」双条件同时成立，才允许跨歌手采纳。
  ///   歌名完全一致不放宽成前后缀包含，是为了压住「同名不同曲」的风险。
  /// - 两边都没有时长 → 无法互相印证，跨歌手时不采纳。
  ///
  /// 打分时会把标题的每种形态各算一次取最高（见 [titleVariants]），
  /// 清洗没覆盖到的书写习惯不该因为多挂了一截就整首被否。
  static int scoreCandidate({
    required String queryTitle,
    required String queryArtist,
    required int? queryDurationMs,
    required String candidateTitle,
    required Iterable<String> candidateArtists,
    required int? candidateDurationMs,
    required int durationToleranceMs,
  }) {
    var best = 0;
    for (final String variant in titleVariants(queryTitle)) {
      final int s = _scoreVariant(
        candidateTitle: candidateTitle,
        queryTitle: variant,
        queryArtist: queryArtist,
        queryDurationMs: queryDurationMs,
        candidateArtists: candidateArtists,
        candidateDurationMs: candidateDurationMs,
        durationToleranceMs: durationToleranceMs,
      );
      if (s > best) best = s;
    }
    return best;
  }

  /// 标题的可能形态，**按可信度降序**：清洗结果 → 各分段 → 原始串。
  ///
  /// 用途有两个：打分时逐个试（见 [scoreCandidate]），以及源层在关键词
  /// 赚不到候选时按序再试一个。
  static List<String> titleVariants(String title) {
    final out = <String>[];
    void add(String s) {
      final t = s.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }

    add(cleanTitle(title));

    final base = _trimEdge(toSimplified(toHalfWidth(title.trim()))
        .replaceFirst(_datePrefix, '')
        .replaceFirst(_leadingBracket, '')
        .replaceAll(_versionParen, '')
        .replaceAll(_cjkDot, ''));
    if (base.isNotEmpty) {
      for (final p in base.split(_dashLoose)) {
        add(p);
      }
      for (final p in base.split(_dashSep)) {
        add(p);
      }
      add(base);
    }
    // 最后一手保险：连上面全部洗完都搜不到，就把**原始串原文**再发一次。
    // 繁体在这里保持原样是故意的——万一某个源只认繁体条目，这是唯一的通路。
    add(title);
    return out;
  }

  static int _scoreVariant({
    required String queryTitle,
    required String queryArtist,
    required int? queryDurationMs,
    required String candidateTitle,
    required Iterable<String> candidateArtists,
    required int? candidateDurationMs,
    required int durationToleranceMs,
  }) {
    if (!sameTitle(queryTitle, candidateTitle)) return 0;

    final exact = normalize(queryTitle) == normalize(candidateTitle);
    final artistHit = queryArtist.isNotEmpty &&
        candidateArtists.any((a) => artistMatches(queryArtist, a));
    final delta = durationDeltaMs(queryDurationMs, candidateDurationMs);

    if (artistHit) {
      if (delta != null && delta > durationToleranceMs) return 0;
    } else {
      if (!exact) return 0;
      if (delta == null) return 0;
      if (delta > crossArtistToleranceMs(queryDurationMs)) return 0;
    }

    var score = 0;
    if (exact) score += 10;
    if (artistHit) score += 8;
    if (delta != null) {
      // 分档加分让「同一歌名的多个版本」里时长最贴近的胜出 ——
      // 翻唱库里往往只有时长能区分版本。
      final ms = delta;
      if (ms <= 2000) {
        score += 12;
      } else if (ms <= 5000) {
        score += 8;
      } else if (ms <= 15000) {
        score += 4;
      } else {
        score += 1;
      }
    }
    return score;
  }

  /// 判断一段文本是否含表意文字（中日韩）。
  ///
  /// 用途：汉字单字信息量远高于拉丁字母，歌名门槛不能按字符数一刀切。
  static final RegExp _cjk = RegExp(
    r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7AF]',
  );

  /// 「包含式匹配」允许的最小长度：含表意文字时 2 字，纯拉丁文 3 字。
  ///
  /// 汉字单字信息量远高于拉丁字母，「晴天」两字已足够唯一，门槛不能一刀切。
  /// [sameTitle] 与 AMLL 索引的宽松兜底共用此判据，避免两处各写一份。
  static int containMinLength(String s) => _cjk.hasMatch(s) ? 2 : 3;

  /// 判断两个歌名是否「基本是同一首」。
  ///
  /// 判据：归一化后相等；或「较短一方是较长一方的前缀 / 后缀」且长度达标
  /// （阈值见 [containMinLength]）。这样既能吸收「晴天」↔「晴天(深情版)」这类
  /// 差异，又不会把 `Intro` 这种短标题全匹配上。
  static bool sameTitle(String a, String b) {
    final na = normalize(a);
    final nb = normalize(b);
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb) return true;
    final shorter = na.length <= nb.length ? na : nb;
    final longer = na.length <= nb.length ? nb : na;
    if (shorter.length < containMinLength(shorter)) return false;
    // 限定在前后缀，避免 `contains` 把「晴天」蒙到「明天晴天了」这类无关标题上。
    return longer.startsWith(shorter) || longer.endsWith(shorter);
  }

  /// 判断两位歌手是否对得上：任一方为空时视为“不反对”，否则要求包含关系。
  static bool artistMatches(String? want, String? got) {
    final nw = normalize(want ?? '');
    final ng = normalize(got ?? '');
    if (nw.isEmpty || ng.isEmpty) return true;
    return nw == ng || nw.contains(ng) || ng.contains(nw);
  }

  /// 时长差（毫秒）；任一为空时返回 null。
  static int? durationDeltaMs(int? wantMs, int? gotMs) {
    if (wantMs == null || gotMs == null) return null;
    return (wantMs - gotMs).abs();
  }

  /// 秒数 → 毫秒。
  static int? secondsToMs(num? seconds) =>
      seconds == null ? null : (seconds * 1000).round();
}
