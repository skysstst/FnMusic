import 'dart:io';

import 'package:flutter_lyric/core/lyric_model.dart' as fl;
import 'package:flutter_test/flutter_test.dart';
import 'package:fnmusic/app/services/lyrics/lyrics_parser.dart';
import 'package:fnmusic/app/services/lyrics/online_lyric_source.dart';
import 'package:fnmusic/app/services/lyrics/sources/lrc_formats.dart';
import 'package:fnmusic/app/services/lyrics/sources/lyric_eligibility.dart';
import 'package:fnmusic/app/services/lyrics/sources/lyric_query.dart';
import 'package:fnmusic/app/services/lyrics/sources/lyric_source.dart';
import 'package:fnmusic/app/state/song_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 真实抓取到的样例数据（见 .tools/_probe_sources*.py 的探测结果），
/// 用真数据做断言，避免「自己造格式、自己解析」的自证循环。
const String kAmllEslrc =
    '[00:29.231]故[00:29.692]事[00:30.057]的[00:30.472]小[00:31.329]黄[00:31.799]花[00:32.723] \n'
    '[00:32.723]从[00:33.132]出[00:33.571]生[00:33.910]那[00:34.319]年[00:34.751]就[00:35.170]飘[00:35.641]着[00:36.238] ';

const String kAmllYrc =
    '[29231,3492](29231,461,0)故(29692,365,0)事(30057,415,0)的(30472,857,0)小(31329,470,0)黄(31799,924,0)花';

const String kAmllQrc =
    '[29231,3492]故(29231,461)事(29692,365)的(30057,415)小(30472,857)黄(31329,470)花';

const String kPlainLrc =
    '[00:25.237]这一路上走走停停\n[00:28.592]顺着少年漂流的痕迹';

const String kNeteaseRichLrc =
    '{"t":0,"c":[{"tx":"作词: "},{"tx":"米果"}]}\n[00:25.237]这一路上走走停停';

const String kTranslationLrc =
    '[00:25.237]All the way, stop and go\n[00:28.592]Following the traces';

SongEntity _song(String guid, String title, String? artist, int durationMs) {
  return SongEntity(
    guid: guid,
    title: title,
    artistDisplay: artist,
    albumDisplay: '专辑',
    durationMs: durationMs,
  );
}

/// 可编排的假歌词源：用回调决定「返回什么 / 抛什么」，并记录调用次数。
class _ScriptedSource extends LyricSource {
  _ScriptedSource(this.id, this.handler, {this.plain = true});

  @override
  final String id;

  final Future<LyricFetchResult?> Function(bool allowPlain) handler;

  /// 本假源是否参与第二轮的「纯文本兜底」。
  final bool plain;

  int calls = 0;

  @override
  String get displayName => '假源 $id';

  @override
  String get description => '单测用';

  @override
  bool get enabledByDefault => true;

  @override
  bool get supportsPlain => plain;

  @override
  Future<LyricFetchResult?> fetch(LyricQuery query, {bool allowPlain = false}) {
    calls++;
    return handler(allowPlain);
  }
}

LyricFetchResult _result(String sourceId, {LyricFormat? format}) {
  return LyricFetchResult(
    content: kPlainLrc,
    sourceId: sourceId,
    format: format ?? LyricFormat.lineSynced,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LrcFormats 格式工具', () {
    test('能识别 AMLL 的 .eslrc 为逐字格式，普通 LRC 不是', () {
      expect(LrcFormats.isWordSynced(kAmllEslrc), isTrue);
      expect(LrcFormats.isWordSynced(kPlainLrc), isFalse);
      expect(LrcFormats.hasSyncedLines(kPlainLrc), isTrue);
      expect(LrcFormats.hasSyncedLines('这是一段没有时间轴的歌词'), isFalse);
    });

    test('sanitize 丢掉网易云富文本行与注释行', () {
      final cleaned = LrcFormats.sanitize(kNeteaseRichLrc);
      expect(cleaned.contains('"tx"'), isFalse);
      expect(cleaned.contains('这一路上走走停停'), isTrue);
      expect(LrcFormats.hasSyncedLines(cleaned), isTrue);
    });

    test('mergeTranslation 按时间戳把翻译并成「原文 / 译文」', () {
      final merged = LrcFormats.mergeTranslation(kPlainLrc, kTranslationLrc);
      expect(
        merged.split('\n').first,
        '[00:25.237]这一路上走走停停 / All the way, stop and go',
      );
    });

    test('mergeTranslation 在没有翻译时原样返回', () {
      final merged = LrcFormats.mergeTranslation(kPlainLrc, null);
      expect(merged, kPlainLrc);
    });

    test('YRC 转增强 LRC 后能被判为逐字', () {
      final converted = LrcFormats.yrcToEnhanced(kAmllYrc);
      expect(converted.startsWith('[00:29.231]故'), isTrue);
      expect(LrcFormats.isWordSynced(converted), isTrue);
      // 收尾时间戳 = 行起点 + 行时长（29231 + 3492 = 32723）
      expect(converted.contains('[00:32.723]'), isTrue);
    });

    test('QRC 转增强 LRC 后能被判为逐字', () {
      final converted = LrcFormats.qrcToEnhanced(kAmllQrc);
      expect(converted.startsWith('[00:29.231]故'), isTrue);
      expect(LrcFormats.isWordSynced(converted), isTrue);
    });
  });

  group('端到端：接上现有解析器即得真逐字', () {
    test('AMLL .eslrc 直接生成带 words 的逐字行', () {
      final fl.LyricModel model = LyricsParser.buildModelFromRaw(
        kAmllEslrc,
        songDuration: const Duration(milliseconds: 269000),
        predictDuration: false,
      );
      expect(model.lines.length, 2);
      expect(model.lines.first.text, '故事的小黄花');
      final words = model.lines.first.words;
      expect(words, isNotNull);
      expect(words!.length, 6);
      expect(words.first.text, '故');
      expect(words.first.start.inMilliseconds, 29231);
      // 第二段起点应与源数据一致
      expect(words[1].start.inMilliseconds, 29692);
    });

    test('普通 LRC 在未开启逐字时不会伪造 words', () {
      final fl.LyricModel model = LyricsParser.buildModelFromRaw(
        kPlainLrc,
        songDuration: const Duration(milliseconds: 269000),
        predictDuration: false,
        forceKaraoke: false,
      );
      expect(model.lines.first.words, isNull);
    });

    test('YRC 转换结果同样能产出逐字行', () {
      final model = LyricsParser.buildModelFromRaw(
        LrcFormats.yrcToEnhanced(kAmllYrc),
        songDuration: const Duration(milliseconds: 269000),
        predictDuration: false,
      );
      expect(model.lines.first.text, '故事的小黄花');
      expect(model.lines.first.words?.length, 6);
    });
  });

  group('归一化与匹配', () {
    test('cleanTitle 去掉版本说明括号', () {
      expect(LyricTextNorm.cleanTitle('起风了 (Live)'), '起风了');
      expect(LyricTextNorm.cleanTitle('晴天（现场版）'), '晴天');
      expect(LyricTextNorm.cleanTitle('Hello'), 'Hello');
    });

    test('primaryArtist 取主歌手', () {
      expect(LyricTextNorm.primaryArtist('周杰伦 / 费玉清'), '周杰伦');
      expect(LyricTextNorm.primaryArtist('冯沁苑(买辣椒也用券)'), '冯沁苑(买辣椒也用券)');
      expect(LyricTextNorm.primaryArtist(null), '');
    });

    test('sameTitle 能吸收版本后缀但不误配短标题', () {
      expect(LyricTextNorm.sameTitle('晴天', '晴天(深情版)'), isTrue);
      expect(LyricTextNorm.sameTitle('起风了', '起风了'), isTrue);
      expect(LyricTextNorm.sameTitle('Intro', 'Interlude'), isFalse);
      expect(LyricTextNorm.sameTitle('晴天', '七里香'), isFalse);
    });

    test('artistMatches 对空值宽容、对不同歌手拒绝', () {
      expect(LyricTextNorm.artistMatches('周杰伦', '周杰伦'), isTrue);
      expect(LyricTextNorm.artistMatches('周杰伦', ''), isTrue);
      expect(LyricTextNorm.artistMatches('周杰伦', '林俊杰'), isFalse);
    });

    test('LyricQuery.fromSong 完成字段映射', () {
      final query = LyricQuery.fromSong(
        _song('g1', '起风了 (Live)', '买辣椒也用券 / 周深', 325000),
      );
      expect(query.title, '起风了');
      expect(query.artist, '买辣椒也用券');
      expect(query.durationMs, 325000);
      expect(query.titleKey, '起风了');
    });

    test('cleanTitle 剥掉「歌名 - 歌手」的尾巴', () {
      // 本曲库把歌手拼进标题，这是第二个歌单的普遍格式。
      expect(
        LyricTextNorm.cleanTitle('宝贝 - 陈一发儿', artist: '陈一发儿'),
        '宝贝',
      );
      expect(
        LyricTextNorm.cleanTitle('Bizarre love triangle - 陈一发儿',
            artist: '陈一发儿'),
        'Bizarre love triangle',
      );
      // 多歌手展示串：尾部与其中任一段对得上就剥。
      expect(
        LyricTextNorm.cleanTitle('成都 - 陈一发儿', artist: '陈一发儿 / 赵雷'),
        '成都',
      );
      // 尾部挂着附加说明也要能剥。
      expect(
        LyricTextNorm.cleanTitle('告一段落 - 陈一发儿 | 原创', artist: '陈一发儿'),
        '告一段落',
      );
    });

    test('cleanTitle 不乱切正常歌名', () {
      // 三段以上的「 - 」本身有歧义 → 一律不动。
      expect(LyricTextNorm.cleanTitle('Love - and - Peace'), 'Love - and - Peace');
      expect(
        LyricTextNorm.cleanTitle('Love - and - Peace', artist: '陈一发儿'),
        'Love - and - Peace',
      );
      // 无空白包围的连字符：两侧都不是歌手名、也不是纯汉字 → 不动。
      expect(LyricTextNorm.cleanTitle('Lo-Fi', artist: '陈一发儿'), 'Lo-Fi');
      expect(LyricTextNorm.cleanTitle('X-Ray', artist: '陈一发儿'), 'X-Ray');
    });

    test('歌手字段为空时靠词表照样能剥', () {
      // 名字在词表里，就不需要歌手字段来确认。这是相对旧实现的改进：
      // 旧版只在「剥掉的那一段恰好等于 artist 参数」时才动手，
      // 于是歌手字段为空的条目（实测 134 条）只能原样留着。
      expect(LyricTextNorm.cleanTitle('宝贝 - 陈一发儿'), '宝贝');
      expect(LyricTextNorm.cleanTitle('陈一发儿 - 水星记'), '水星记');
    });

    test('fromSong 对「歌名 - 歌手」式标题产出可精确匹配的 titleKey', () {
      final query = LyricQuery.fromSong(
        _song('g2', '宝贝 - 陈一发儿', '陈一发儿', 146000),
      );
      expect(query.title, '宝贝');
      expect(query.artist, '陈一发儿');
      expect(query.titleKey, '宝贝');
      // 剥干净之后，跨歌手兜底所依赖的「歌名完全一致」才成立。
      expect(
        query.titleKey == LyricTextNorm.normalize('宝贝'),
        isTrue,
      );
    });
  });

  /// 下面这些字符串**直接取自账号里的真实曲库**（两个歌单共 262 条里
  /// 95 条带这种拼接），不是编出来的样例 —— 回归时别把它们「整理干净」。
  group('曲库真实标题形态', () {
    test('歌手在前（歌手字段为空）也能剥：陈一发儿 - 水星记', () {
      final query = LyricQuery.fromSong(
        _song('g10', '陈一发儿 - 水星记', null, 285599),
      );
      expect(query.artist, '');
      expect(query.title, '水星记');
      expect(
        LyricTextNorm.scoreCandidate(
          queryTitle: query.title,
          queryArtist: query.artist,
          queryDurationMs: query.durationMs,
          candidateTitle: '水星记',
          candidateArtists: const <String>['郭顶'],
          candidateDurationMs: 285000,
          durationToleranceMs: 4000,
        ),
        greaterThan(0),
      );
    });

    test('歌手在前且歌手字段有值时同样剥', () {
      expect(
        LyricTextNorm.cleanTitle('陈一发儿 - 白山茶', artist: '陈一发儿'),
        '白山茶',
      );
    });

    test('歌手在后（本曲库更常见的一侧）不受影响', () {
      expect(
        LyricTextNorm.cleanTitle('打错了 - 陈一发儿', artist: '陈一发儿'),
        '打错了',
      );
      expect(
        LyricTextNorm.cleanTitle('历历万乡 - 陈一发儿', artist: '陈一发儿'),
        '历历万乡',
      );
    });

    test('多段「 - 」不猜（歧义），原样保留', () {
      final query = LyricQuery.fromSong(
        _song('g11', 'Love - and - Peace', null, 200000),
      );
      expect(query.title, 'Love - and - Peace');
    });

    test('括号版式说明扩展：想你的365天 (Cover)', () {
      expect(LyricTextNorm.cleanTitle('想你的365天 (Cover)'), '想你的365天');
      expect(LyricTextNorm.cleanTitle('起风了 (Live)'), '起风了');
      expect(LyricTextNorm.cleanTitle('说谎[KTV]'), '说谎');
    });

    test('无空格连字符也能剥（木兰星- / 克卜勒－）', () {
      expect(
        LyricTextNorm.cleanTitle('木兰星-陈一发儿', artist: '陈一发儿'),
        '木兰星',
      );
      expect(
        LyricTextNorm.cleanTitle('克卜勒－陈一发儿', artist: '陈一发儿'),
        '克卜勒',
      );
      expect(
        LyricTextNorm.cleanTitle('她来听我的演唱会-陈一发儿', artist: '陈一发儿'),
        '她来听我的演唱会',
      );
    });

    test('无空格连字符的兜底不得误伤正常歌名', () {
      // 两侧都不是词表里的人名，也不是纯汉字 → 等于没切。
      expect(LyricTextNorm.cleanTitle('Lo-Fi', artist: '陈一发儿'), 'Lo-Fi');
      expect(LyricTextNorm.cleanTitle('X-Ray', artist: '陈一发儿'), 'X-Ray');
      expect(
        LyricTextNorm.cleanTitle('Love - and - Peace', artist: '陈一发儿'),
        'Love - and - Peace',
      );
    });

    test('日期前缀（四种写法）都能剥', () {
      // 全库 9,000+ 条是这种「日期 + 歌手-歌名」，剥不掉就一条都搜不到。
      expect(
        LyricTextNorm.cleanTitle('16.12.15陈一发儿-城里的月光', artist: '陈一发儿'),
        '城里的月光',
      );
      expect(LyricTextNorm.cleanTitle('20240106－魚'), '鱼');
      expect(LyricTextNorm.cleanTitle('220716－陰天'), '阴天');
      expect(LyricTextNorm.cleanTitle('2024.01.06 晴天'), '晴天');
      expect(LyricTextNorm.cleanTitle('2015.10.29 Lana Del Rey-Young And Beautiful'),
          'Young And Beautiful');
    });

    test('拉丁歌手在前：头段多词、无汉字 → 取尾段', () {
      // 全库这种形态只有 9 条，但全是「英文歌手-英文歌名」，零反例。
      expect(
        LyricTextNorm.cleanTitle('2015.10.29 Lana Del Rey-Young And Beautiful'),
        'Young And Beautiful',
      );
      expect(LyricTextNorm.cleanTitle('16.7.24Don Mclean-Vincent'), 'Vincent');
      expect(
        LyricTextNorm.cleanTitle('2015.10.9 Leo Sayer-More Than I Can Say（崩）'),
        'More Than I Can Say',
      );
    });

    test('单词头段绝不能切：Mad-World / Lonely-Christmas 本身就是歌名', () {
      // 这两条是**歌名里的横线**，切了会搜成 `World` / `Christmas`，比不切更糟。
      // 所以拉丁规则必须卡「头段 ≥ 2 个词」——宁可漏掉 `lenka-the show`。
      expect(LyricTextNorm.cleanTitle('Mad-World（修复 ）'), 'Mad-World');
      expect(LyricTextNorm.cleanTitle('Lonely-Christmas（修复）'), 'Lonely-Christmas');
    });

    test('原唱者不在词表里时，靠「两侧纯汉字 + 头段短」剥', () {
      // 实测 202 条这种形态，头段全是原唱者名字（王菲 / 蔡幸娟 / 莫文蔚…），
      // 词表不可能穷举所有原唱。
      expect(LyricTextNorm.cleanTitle('16.6.8王菲-当时的月亮'), '当时的月亮');
      expect(LyricTextNorm.cleanTitle('2015.9.27 张惠妹-如果你也听说'), '如果你也听说');
      // 嘉宾名同理。
      expect(LyricTextNorm.cleanTitle('16.5.25杠姐家做客-茶汤（崩）'), '茶汤');
    });

    test('开头方括号栏目块要剥掉', () {
      expect(LyricTextNorm.cleanTitle('【暗杠校园游】走歌人'), '走歌人');
    });

    test('汉字中间的间隔号要抹掉', () {
      // 曲库里真的录成了 `但愿人长.久（修复）`，不抹掉所有渠道都搜不到。
      expect(LyricTextNorm.cleanTitle('但愿人长.久（修复）'), '但愿人长久');
    });

    test('「歌名 + 空格 + 人名」的尾巴要剥掉', () {
      expect(LyricTextNorm.cleanTitle('20241026－淚橋 趙小臭'), '泪桥');
      // 英文标题不能被这条规则切坏。
      expect(LyricTextNorm.cleanTitle('Young And Beautiful'), 'Young And Beautiful');
    });

    test('表情符号不进搜索词', () {
      expect(LyricTextNorm.cleanTitle('20240525－同桌的你 🎸'), '同桌的你');
    });

    test('头段歌手挂着别人时，整条仍是歌名', () {
      // `陈一发儿、暗杠-外面的世界` 是一首合唱，不能因为「含主播名」被丢掉。
      expect(
        LyricTextNorm.cleanTitle('陈一发儿、暗杠-外面的世界', artist: '陈一发儿'),
        '外面的世界',
      );
    });

    test('titleVariants 兜底：清洗漏掉的残留也不会整首被否', () {
      expect(
        LyricTextNorm.titleVariants('陈一发儿 - 水星记'),
        contains('水星记'),
      );
      final score = LyricTextNorm.scoreCandidate(
        // 故意用**没清洗过**的原始标题，验证变体兜底确实生效。
        queryTitle: '陈一发儿 - 水星记',
        queryArtist: '',
        queryDurationMs: 285599,
        candidateTitle: '水星记',
        candidateArtists: const <String>['郭顶'],
        candidateDurationMs: 285000,
        durationToleranceMs: 4000,
      );
      expect(score, greaterThan(0));
    });
  });

  group('繁简与跨歌手匹配', () {
    test('繁转简后歌名可相等：阿婆說 / 阿婆说', () {
      expect(LyricTextNorm.toSimplified('阿婆說'), '阿婆说');
      expect(LyricTextNorm.toSimplified('從前慢'), '从前慢');
      expect(LyricTextNorm.sameTitle('阿婆說', '阿婆说'), isTrue);
      expect(LyricTextNorm.sameTitle('從前慢', '从前慢 (Live)'), isTrue);
    });

    test('挂着罕见异体的首候选也要转：願 → 愿', () {
      // OpenCC 里 `願 → 愿 𫖸`（首候选是规范简化字，后面跟罕见异体）。
      // 早先的生成规则只留「单候选」行，把这条漏了 ⇒ `但願人長久` 搜不到词。
      expect(LyricTextNorm.toSimplified('願'), '愿');
      expect(LyricTextNorm.toSimplified('但願人長久'), '但愿人长久');
      expect(LyricTextNorm.sameTitle('但願人長久', '但愿人长久'), isTrue);
      expect(
        LyricTextNorm.normalize('但願人長久') ==
            LyricTextNorm.normalize('但愿人长久'),
        isTrue,
      );
    });

    test('本来就是简体的歌名不受影响', () {
      expect(LyricTextNorm.toSimplified('成都'), '成都');
      expect(LyricTextNorm.normalize('晴天'), '晴天');
    });

    test('歌手对不上，但歌名一致 + 时长贴合 → 采纳（翻唱库场景）', () {
      final score = LyricTextNorm.scoreCandidate(
        queryTitle: '阿婆說',
        queryArtist: '陈一发儿',
        queryDurationMs: 247000,
        candidateTitle: '阿婆说',
        candidateArtists: const <String>['暗杠'],
        candidateDurationMs: 241333,
        durationToleranceMs: 4000,
      );
      expect(score, greaterThan(0));
    });

    test('歌手对不上且时长差得离谱 → 否决（防同名不同曲）', () {
      final score = LyricTextNorm.scoreCandidate(
        queryTitle: '成都',
        queryArtist: '陈一发儿',
        queryDurationMs: 288000,
        candidateTitle: '成都',
        candidateArtists: const <String>['某某乐队'],
        candidateDurationMs: 600000,
        durationToleranceMs: 4000,
      );
      expect(score, 0);
    });

    test('同名多版本里，时长最贴近的得分更高', () {
      int s(int candidateMs) => LyricTextNorm.scoreCandidate(
            queryTitle: '阿婆說',
            queryArtist: '陈一发儿',
            queryDurationMs: 247000,
            candidateTitle: '阿婆说',
            candidateArtists: const <String>['某某'],
            candidateDurationMs: candidateMs,
            durationToleranceMs: 4000,
          );
      expect(s(245000), greaterThan(s(269000)));
    });

    test('歌手对得上时，沿用各源自己的紧容差', () {
      final ok = LyricTextNorm.scoreCandidate(
        queryTitle: '晴天',
        queryArtist: '周杰伦',
        queryDurationMs: 269000,
        candidateTitle: '晴天',
        candidateArtists: const <String>['周杰伦'],
        candidateDurationMs: 270000,
        durationToleranceMs: 2000,
      );
      expect(ok, greaterThan(0));

      final tooFar = LyricTextNorm.scoreCandidate(
        queryTitle: '晴天',
        queryArtist: '周杰伦',
        queryDurationMs: 269000,
        candidateTitle: '晴天',
        candidateArtists: const <String>['周杰伦'],
        candidateDurationMs: 300000,
        durationToleranceMs: 2000,
      );
      expect(tooFar, 0);
    });

    test('跨歌手容差：绝对下限 10 秒、相对 12% 取较大者', () {
      expect(LyricTextNorm.crossArtistToleranceMs(60000), 10000);
      expect(LyricTextNorm.crossArtistToleranceMs(240000), 28800);
    });
  });

  group('OnlineLyricSource 多源兜底', () {
    late Directory tempDir;
    var seq = 0;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fnlyrics_test');
      OnlineLyricSource.missStorePathOverride =
          '${tempDir.path}${Platform.pathSeparator}misses.json';
      SharedPreferences.setMockInitialValues(<String, Object>{});
      OnlineLyricSource.instance.resetForTest();
      await OnlineLyricSource.instance.refreshSettings();
    });

    tearDown(() async {
      OnlineLyricSource.sourcesOverride = null;
      OnlineLyricSource.missStorePathOverride = null;
      OnlineLyricSource.instance.resetForTest();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    String uid(String base) => '${base}_${seq++}';

    test('前一个源落空时自动降级到下一个源', () async {
      final idA = uid('a');
      final idB = uid('b');
      final a = _ScriptedSource(idA, (_) async => null);
      final b = _ScriptedSource(idB, (_) async => _result(idB));
      OnlineLyricSource.sourcesOverride = <LyricSource>[a, b];

      final hit = await OnlineLyricSource.instance
          .fetchForSong(_song('song1', '晴天', '周杰伦', 269000));

      expect(hit, isNotNull);
      expect(hit!.sourceId, idB);
      expect(a.calls, 1);
      expect(b.calls, 1);
    });

    test('被限流的源进入冷却，后续歌曲直接跳过', () async {
      final idA = uid('rl');
      final idB = uid('ok');
      final a = _ScriptedSource(
        idA,
        (_) async => throw LyricRateLimitedException(
          idA,
          retryAfter: const Duration(minutes: 5),
        ),
      );
      final b = _ScriptedSource(idB, (_) async => _result(idB));
      OnlineLyricSource.sourcesOverride = <LyricSource>[a, b];

      final first = await OnlineLyricSource.instance
          .fetchForSong(_song('s1', '晴天', '周杰伦', 269000));
      expect(first, isNotNull);
      expect(first!.sourceId, idB);
      expect(a.calls, 1);

      final second = await OnlineLyricSource.instance
          .fetchForSong(_song('s2', '七里香', '周杰伦', 299000));
      expect(second!.sourceId, idB);
      // 冷却期内不再请求被限流的源
      expect(a.calls, 1);
    });

    test('被限流 ≠ 这首歌没歌词：不得写进失败记忆', () async {
      final idA = uid('rl2');
      var limited = true;
      final a = _ScriptedSource(
        idA,
        (_) async {
          if (limited) {
            throw LyricRateLimitedException(
              idA,
              retryAfter: const Duration(milliseconds: 1),
            );
          }
          return _result(idA);
        },
        // 不参与第二轮纯文本兜底，保证每次 fetch 只调用一次，便于计数。
        plain: false,
      );
      OnlineLyricSource.sourcesOverride = <LyricSource>[a];
      final song = _song('s_rl', '晴天', '周杰伦', 269000);

      // 第一次被限流：本轮拿不到词，但这**不代表**「这首歌在这个源上没有词」。
      expect(await OnlineLyricSource.instance.fetchForSong(song), isNull);
      expect(a.calls, 1);

      // 若实现把「被限流」误当成「已试过且无结果」，下面这次会被负缓存
      // 直接 skip、连问都不问 —— 用户侧就是「以前能搜到，现在怎么都搜不到」。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      limited = false;
      final again = await OnlineLyricSource.instance.fetchForSong(song);
      expect(again, isNotNull);
      expect(again!.sourceId, idA);
      expect(a.calls, 2);
    });

    test('全部源落空时写失败记忆，再次请求不重复联网', () async {
      final idA = uid('miss_a');
      final idB = uid('miss_b');
      // A 不支持纯文本兜底，用来验证第二轮只会问 supportsPlain 的源。
      final a = _ScriptedSource(idA, (_) async => null, plain: false);
      final b = _ScriptedSource(idB, (_) async => null);
      OnlineLyricSource.sourcesOverride = <LyricSource>[a, b];
      final song = _song('s_miss', '冷门歌', '某某', 200000);

      expect(await OnlineLyricSource.instance.fetchForSong(song), isNull);
      expect(a.calls, 1); // 只参与第一轮
      expect(b.calls, 2); // 两轮都参与

      expect(await OnlineLyricSource.instance.fetchForSong(song), isNull);
      expect(a.calls, 1); // 命中失败记忆，没有新增请求
      expect(b.calls, 2);
    });

    test('第二轮允许退到无时间轴的纯文本', () async {
      final idA = uid('plain');
      final a = _ScriptedSource(
        idA,
        (allowPlain) async => allowPlain
            ? _result(idA, format: LyricFormat.plain)
            : null,
      );
      OnlineLyricSource.sourcesOverride = <LyricSource>[a];

      final hit = await OnlineLyricSource.instance
          .fetchForSong(_song('s_plain', '冷门歌', '某某', 200000));
      expect(hit, isNotNull);
      expect(hit!.format, LyricFormat.plain);
      expect(a.calls, 2);
    });

    test('同一首歌的并发请求合并为一次', () async {
      final idA = uid('single');
      final a = _ScriptedSource(idA, (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return _result(idA);
      });
      OnlineLyricSource.sourcesOverride = <LyricSource>[a];
      final song = _song('s_single', '晴天', '周杰伦', 269000);

      final results = await Future.wait(<Future<LyricFetchResult?>>[
        OnlineLyricSource.instance.fetchForSong(song),
        OnlineLyricSource.instance.fetchForSong(song),
      ]);

      expect(results[0], isNotNull);
      expect(results[1], isNotNull);
      expect(a.calls, 1);
    });

    test('关闭总开关后完全不联网', () async {
      final idA = uid('off');
      final a = _ScriptedSource(idA, (_) async => _result(idA));
      OnlineLyricSource.sourcesOverride = <LyricSource>[a];
      await OnlineLyricSource.instance.setEnabled(false);

      final hit = await OnlineLyricSource.instance
          .fetchForSong(_song('s_off', '晴天', '周杰伦', 269000));

      expect(hit, isNull);
      expect(a.calls, 0);
    });

    test('源暂时不可用时跳过，但不得把它写进失败记忆', () async {
      final idA = uid('notready');
      final idB = uid('later');
      var aReady = false;
      final a = _ScriptedSource(idA, (_) async {
        if (!aReady) {
          throw LyricSourceNotReadyException(idA, '索引尚未下载完');
        }
        return _result(idA);
      });
      final b = _ScriptedSource(idB, (_) async => null, plain: false);
      OnlineLyricSource.sourcesOverride = <LyricSource>[a, b];
      final song = _song('s_notready', '冷门歌', '某某', 200000);

      // 第一遍：A 未就绪、B 真落空 → 全部无结果
      expect(await OnlineLyricSource.instance.fetchForSong(song), isNull);

      // A 就绪后重来：第一遍只把 B 记进了失败记忆，所以 A 仍会被问到
      aReady = true;
      final hit = await OnlineLyricSource.instance.fetchForSong(song);
      expect(hit, isNotNull);
      expect(hit!.sourceId, idA);
    });

    test('连通性自检：拿到词就是 ok，并带上粒度与字数', () async {
      final idA = uid('probe_ok');
      final a = _ScriptedSource(
        idA,
        (_) async => _result(idA, format: LyricFormat.wordSynced),
      );
      OnlineLyricSource.sourcesOverride = <LyricSource>[a];

      final r = await OnlineLyricSource.instance.probe(a);

      expect(r.status, LyricProbeStatus.ok);
      expect(r.ok, isTrue);
      expect(r.format, LyricFormat.wordSynced);
      expect(r.chars, kPlainLrc.length);
      expect(r.message, contains('逐字歌词'));
      expect(a.calls, 1);
      // 自检不落失败记忆：这首歌不该被记住
      expect(
        await OnlineLyricSource.instance.fetchForSong(
          _song('s_probe_ok', '晴天', '周杰伦', 269000),
        ),
        isNotNull,
      );
    });

    test('连通性自检：能连上但探针歌取不到词 → noResult（区别于 failed）', () async {
      final idA = uid('probe_none');
      final a = _ScriptedSource(idA, (_) async => null);
      OnlineLyricSource.sourcesOverride = <LyricSource>[a];

      final r = await OnlineLyricSource.instance.probe(a);

      expect(r.status, LyricProbeStatus.noResult);
      expect(r.ok, isFalse);
      // 结论里必须点出「是接口改版，不是这首歌没有」，否则用户没法判断。
      expect(r.message, contains('改版'));
    });

    test('连通性自检：报错 → failed；暂时不可用 → notReady', () async {
      final failId = uid('probe_fail');
      final failSrc = _ScriptedSource(
        failId,
        (_) async => throw LyricSourceException(failId, '连接被重置'),
      );
      final notReadyId = uid('probe_nr');
      final nrSrc = _ScriptedSource(
        notReadyId,
        (_) async => throw LyricSourceNotReadyException(notReadyId, '索引还没下完'),
      );
      OnlineLyricSource.sourcesOverride = <LyricSource>[failSrc, nrSrc];

      final f = await OnlineLyricSource.instance.probe(failSrc);
      expect(f.status, LyricProbeStatus.failed);
      expect(f.message, contains('连接被重置'));

      final n = await OnlineLyricSource.instance.probe(nrSrc);
      expect(n.status, LyricProbeStatus.notReady);
      expect(n.message, contains('索引还没下完'));
    });

    test('连通性自检：被限流会进冷却，但再点「测试」必须能测（先清冷却）', () async {
      final idA = uid('probe_rl');
      var limited = true;
      final a = _ScriptedSource(idA, (_) async {
        if (limited) {
          throw LyricRateLimitedException(
            idA,
            retryAfter: const Duration(minutes: 5),
          );
        }
        return _result(idA);
      });
      OnlineLyricSource.sourcesOverride = <LyricSource>[a];

      final r1 = await OnlineLyricSource.instance.probe(a);
      expect(r1.status, LyricProbeStatus.rateLimited);
      expect(r1.message, contains('限流'));
      // 自检顺带把冷却状态同步出来，供设置页画圆点。
      expect(OnlineLyricSource.instance.isCoolingDown(idA), isTrue);

      // 关键：冷却期内点「测试」不能直接被冷却挡掉，否则用户永远测不出
      // 「其实已经恢复了」——自检的目的就是验证当下能不能用。
      limited = false;
      final r2 = await OnlineLyricSource.instance.probe(a);
      expect(r2.status, LyricProbeStatus.ok);
    });

    test('每个源都有自己的探针歌，且必须是该源一定有的歌', () {
      // 探针歌选错（用了冷门歌）会让「渠道挂了」和「这首歌太偏」分不开，
      // 整个测试按钮就失去意义了，所以这里把它当契约固定下来。
      final sources = OnlineLyricSource.instance.sources;
      final ids = sources.map((s) => s.id).toList();
      expect(ids, containsAll(<String>[
        'qqmusic',
        'kugou',
        'kuwo',
        'netease',
        'lrclib',
        'amll',
      ]));
      for (final s in sources) {
        expect(s.probeQuery.title, isNotEmpty, reason: '${s.id} 没配探针歌');
        expect(s.probeQuery.artist, isNotEmpty, reason: '${s.id} 探针歌缺歌手');
        expect(s.probeQuery.durationMs, isNotNull, reason: '${s.id} 探针歌缺时长');
        // 时长要对得上——LRCLIB 的 /api/get 会按 ±2 秒硬校验时长。
        expect(s.probeQuery.durationMs, greaterThan(60000));
      }
    });
  });

  group('LyricEligibility 刮削资格过滤', () {
    LyricSkipReason? check(
      String title, {
      String? artist = '陈一发儿',
      int? durationMs = 200000,
    }) {
      return LyricEligibility.check(
        title: title,
        artist: artist,
        durationMs: durationMs,
      );
    }

    test('正常歌名一律放行', () {
      expect(check('20250125－當時的月亮'), isNull);
      expect(check('16.6.8王菲-当时的月亮'), isNull);
      expect(check('2015.10.29 Lana Del Rey-Young And Beautiful'), isNull);
      expect(check('20241026－淚橋 趙小臭'), isNull);
      expect(check('小幸运'), isNull);
      // 时长未知（流媒体没给）时不得因此被毙
      expect(check('小幸运', durationMs: null), isNull);
      expect(check('小幸运', durationMs: 0), isNull);
    });

    test('空标题', () {
      expect(check('')!.code, 'empty_title');
      expect(check('   ')!.code, 'empty_title');
    });

    test('时长两端：不到 1 分钟 / 超过 8 分钟', () {
      expect(check('小幸运', durationMs: 45000)!.code, 'too_short');
      expect(check('小幸运', durationMs: 60000), isNull); // 边界含
      expect(check('小幸运', durationMs: 480000), isNull); // 边界含
      expect(check('小幸运', durationMs: 480001)!.code, 'too_long');
      // 直播回放：全库 1,294 首这种，是过滤掉的主体
      expect(
        check('20180310 李宗盛专场上半场（全程）', durationMs: 11231000)!.code,
        'too_long',
      );
    });

    test('伴奏 / 纯音乐：没有词可刮', () {
      expect(check('小幸运（伴奏）')!.code, 'instrumental');
      expect(check('小幸运 Off Vocal')!.code, 'instrumental');
    });

    test('清唱：用户明确说可以跳过', () {
      expect(check('后来 清唱版')!.code, 'acappella');
      expect(check('后来 A Cappella')!.code, 'acappella');
    });

    test('直播 / 播客栏目：带横线的栏目名', () {
      expect(check('六周年茶话会 - 飞鸟和蝉（一歌）')!.code, 'broadcast');
      expect(check('20180610战神4直播合集－day7')!.code, 'broadcast');
    });

    test('直播话题：不带横线的一整句话', () {
      expect(
        check('这是一个很长很长的话题式开头你们觉得怎么样呢')!.code,
        'broadcast_topic',
      );
    });

    test('清洗完什么都不剩（只有日期）', () {
      expect(check('16.12.15', durationMs: 0)!.code, 'empty_after_clean');
      expect(check('20240106', durationMs: 0)!.code, 'empty_after_clean');
    });

    test('标题里点着主播名 → 直播话题，不是歌', () {
      // 这条规则**必须跑在清洗之后**：清洗前的串本来就带「陈一发儿」这一截
      // 歌手段，在清洗前判会把整个曲库误杀（实测 5,299 首被冤枉过）。
      expect(check('陈一发儿的日常')!.code, 'self_topic');
      expect(check('17.8.23陈一发儿-梦伴'), isNull); // 清洗掉歌手名后是正常歌
    });

    test('过长且像话题', () {
      expect(
        check('歌名-这是一句很长很长的话题式标题，你们说是不是呢对吧')!.code,
        'long_topic',
      );
    });

    test('每条理由都带人话说明，设置页和日志直接能用', () {
      for (final r in <LyricSkipReason>[
        check('')!,
        check('小幸运', durationMs: 1000)!,
        check('小幸运（伴奏）')!,
      ]) {
        expect(r.code, isNotEmpty);
        expect(r.label, isNotEmpty);
        expect(r.toString(), contains(r.code));
      }
    });
  });
}
