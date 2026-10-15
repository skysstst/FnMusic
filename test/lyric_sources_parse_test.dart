import 'package:flutter_test/flutter_test.dart';
import 'package:fnmusic/app/services/lyrics/sources/kugou_source.dart';
import 'package:fnmusic/app/services/lyrics/sources/kuwo_source.dart';

/// 酷狗 / 酷我的**解析层**单测（不联网）。
///
/// 为什么单独锁这两个源：它们的接口是本项目里最「不合规」的两个——
/// - 酷我搜索返回的不是合法 JSON（键用单引号、正文带 `&nbsp;`），只能正则取值；
/// - 酷我歌词给的是**秒字符串**，要自己拼 `[mm:ss.cc]`；
/// - 酷狗部分接口不返回 `application/json`，Dio 给的是裸 String。
/// 这三处坏了都不会抛异常、只会**静默返回空**，靠日志很难发现，所以钉死在这里。

/// 真实抓下来的酷我搜索响应形态（`search.kuwo.cn/r.s`，`rformat=json` 也一样不合规）。
const String kKuwoSearch = "{'abslist':[],'show':'','total':'2','pn':'0','rn':'20',"
    "'ARTIST':'周杰伦','SONGNAME':'晴天&nbsp;(KTV版伴奏)',"
    "'MUSICRID':'MUSIC_123456','DURATION':'269',"
    "'ARTIST':'周杰伦','SONGNAME':'晴天',"
    "'MUSICRID':'MUSIC_789012','DURATION':'269'}";

/// 真实抓下来的酷我歌词响应（`m.kuwo.cn/newh5/singles/songinfoandlrc`）。
const String kKuwoLyric = '\n\n'
    '{"data":{"lrclist":['
    '{"time":"29.26","lineLyric":"故事的小黄花"},'
    '{"time":"32.72","lineLyric":"从出生那年就飘着"},'
    '{"time":"36.17","lineLyric":""}'
    ']}}';

void main() {
  group('KuwoSource 解析层', () {
    test('搜索响应是非法 JSON：按字段正则照样能取到', () {
      final ids = KuwoSource.pickAllForTest(
        kKuwoSearch,
        r"'MUSICRID':'(?:MUSIC_)?(\d+)'",
      );
      expect(ids, <String>['123456', '789012']);

      final names =
          KuwoSource.pickAllForTest(kKuwoSearch, r"'SONGNAME':'([^']*)'");
      expect(names, <String>['晴天&nbsp;(KTV版伴奏)', '晴天']);

      final durations =
          KuwoSource.pickAllForTest(kKuwoSearch, r"'DURATION':'(\d+)'");
      expect(durations, <String>['269', '269']);
    });

    test('HTML 实体要还原，否则搜索词会带着 &nbsp; 去查', () {
      expect(
        KuwoSource.unescapeForTest('晴天&nbsp;(KTV版伴奏)'),
        '晴天 (KTV版伴奏)',
      );
      expect(
        KuwoSource.unescapeForTest('A&amp;B&lt;C&gt;D&quot;E&#39;F'),
        'A&B<C>D"E\'F',
      );
    });

    test('非法 JSON 不能被硬解：解不出就返回 null，不抛异常打断整条链路', () {
      // 单引号键 → jsonDecode 必炸，这里必须吞掉并返回 null。
      expect(KuwoSource.decodeForTest(kKuwoSearch), isNull);
    });

    test('合法 JSON 但要先截断到首个 { 与末个 }', () {
      // 该接口会在 JSON 前面先甩几行空行。
      final decoded = KuwoSource.decodeForTest(kKuwoLyric) as Map?;
      expect(decoded, isNotNull);
      final data = decoded!['data'] as Map;
      expect((data['lrclist'] as List).length, 3);
    });

    test('空串 / 解析不出 → null；已是对象则原样透传', () {
      expect(KuwoSource.decodeForTest('   '), isNull);
      expect(KuwoSource.decodeForTest('这不是 JSON'), isNull);
      expect(KuwoSource.decodeForTest('{残缺'), isNull);
      final passthrough = <String, Object?>{'a': 1};
      expect(KuwoSource.decodeForTest(passthrough), same(passthrough));
    });

    test('歌词是「秒」字符串，要拼成 [mm:ss.cc]', () {
      final rows = ((KuwoSource.decodeForTest(kKuwoLyric)! as Map)['data']
          as Map)['lrclist']! as List<Object?>;
      final lrc = KuwoSource.buildLrcForTest(rows);

      expect(lrc.split('\n')[0], '[00:29.26]故事的小黄花');
      expect(lrc.split('\n')[1], '[00:32.72]从出生那年就飘着');
      // 空行歌词直接丢掉，不留空时间戳
      expect(lrc.contains('36.17'), isFalse);
      expect(lrc.contains('[]'), isFalse);
    });

    test('时间戳进位与补零都对', () {
      String one(String time) => KuwoSource.buildLrcForTest(<Object?>[
            <String, Object?>{'time': time, 'lineLyric': 'x'},
          ]).trim();

      expect(one('0'), '[00:00.00]x');
      expect(one('0.05'), '[00:00.05]x');
      expect(one('9.999'), '[00:10.00]x'); // 四舍五入到 1000 厘秒 = 10.00s
      expect(one('59.99'), '[00:59.99]x');
      expect(one('60'), '[01:00.00]x');
      // 长曲：分钟位不进位到小时，LRC 允许 mm > 59
      expect(one('3675.5'), '[61:15.50]x');
    });

    test('脏行不能把整段歌词带崩', () {
      final lrc = KuwoSource.buildLrcForTest(<Object?>[
        '这是个非 map 的行',
        null,
        <String, Object?>{'lineLyric': '只有词没有时间'},
        <String, Object?>{'time': 'abc', 'lineLyric': '时间不是数字'},
        <String, Object?>{'time': '12.34', 'lineLyric': '正常一行'},
      ]);
      final lines = lrc.split('\n').where((e) => e.isNotEmpty).toList();
      // 前两条被丢掉；后两条时间兜底为 0 但仍产出，最后才是正常行
      expect(lines.last, '[00:12.34]正常一行');
      expect(lines.every((e) => e.startsWith('[')), isTrue);
    });
  });

  group('KugouSource 解析层', () {
    test('裸 String 也要能解出 JSON（部分接口不给 application/json）', () {
      final decoded = KugouSource.decodeForTest(
        '{"status":1,"data":{"lists":[{"hash":"ABC"}]}}',
      );
      expect(decoded, isA<Map>());
      expect(((decoded! as Map)['data'] as Map)['lists'], isA<List>());
    });

    test('空串 / 非法内容 → null，不抛异常', () {
      expect(KugouSource.decodeForTest(''), isNull);
      expect(KugouSource.decodeForTest('   '), isNull);
      expect(KugouSource.decodeForTest('<html>被挡住了</html>'), isNull);
    });

    test('已经是对象时原样透传', () {
      final passthrough = <String, Object?>{'status': 1};
      expect(KugouSource.decodeForTest(passthrough), same(passthrough));
    });
  });
}
