import 'package:flutter_test/flutter_test.dart';
import 'package:rrha/data/bili/bili_content_parser.dart';
import 'package:rrha/data/bili/bili_timeline_source.dart';

/// 动态详情的**评论入口**解析（2026-11-02）。
///
/// ## 为什么这一条必须单独测
///
/// 用户给的那条样本 `/opus/1266051909563711506` 暴露了一个很容易踩的坑：
/// opus 链接里那段数字**不是**评论接口的 `oid`。拿它配 `type=11`（图文动态）
/// 或 `type=17`（转发动态）都返回 `-404 啥都木有`（探针
/// `.env/probe_bili_opus_comment_entry.py` 实证）。
///
/// 正确入口只在 `item.basic.comment_id_str` + `comment_type` 里：
/// 那条动态的实际值是 `oid=414185073, type=11` —— 与链接里的数字毫无关系。
///
/// 所以「按动态链接打开」必须：先请求 detail 接口 → 从 basic 取入口 → 再查评论。
/// 一旦有人在中间「顺手复用」链接里的 id，评论就会整块消失。
void main() {
  Map<String, dynamic> detailItem({
    Object? commentId = '414185073',
    Object? commentType = 11,
    String idStr = '1266051909563711506',
  }) =>
      <String, dynamic>{
        'id_str': idStr,
        'type': 'DYNAMIC_TYPE_DRAW',
        'basic': <String, dynamic>{
          'comment_id_str': commentId,
          'comment_type': commentType,
        },
        'modules': <String, dynamic>{
          'module_author': <String, dynamic>{
            'name': '某位 UP',
            'mid': 123,
            'face': 'https://i0.hdslb.com/bfs/face/x.jpg',
            'pub_ts': 1700000000,
          },
          'module_dynamic': <String, dynamic>{
            'desc': <String, dynamic>{'text': '动态正文'},
          },
        },
      };

  group('commentEntryOf：取真实评论入口', () {
    test('图文动态：oid 来自 basic.comment_id_str，不是链接 id', () {
      final entry = BiliContentParser.commentEntryOf(detailItem());

      expect(entry, isNotNull);
      expect(entry!.oid, '414185073');
      expect(entry.type, 11);
      expect(
        entry.oid,
        isNot('1266051909563711506'),
        reason: '用链接里的 id 查评论会 -404，这是本条测试存在的理由',
      );
    });

    test('视频投稿动态：type=1，oid 是 aid', () {
      final entry = BiliContentParser.commentEntryOf(
        detailItem(commentId: '117535185830050', commentType: 1),
      );
      expect(entry!.oid, '117535185830050');
      expect(entry.type, 1);
    });

    test('转发动态：type=17，oid 是该动态 id_str', () {
      final entry = BiliContentParser.commentEntryOf(
        detailItem(commentId: '1266051909563711506', commentType: 17),
      );
      expect(entry!.type, 17);
      expect(entry.oid, '1266051909563711506');
    });

    test('comment_type 是数字字符串也能识别', () {
      final entry = BiliContentParser.commentEntryOf(
        detailItem(commentType: '11'),
      );
      expect(entry!.type, 11);
    });

    test('comment_id_str 缺失 → null（转发原动态的真实情况）', () {
      expect(BiliContentParser.commentEntryOf(detailItem(commentId: null)), isNull);
      expect(BiliContentParser.commentEntryOf(detailItem(commentId: '')), isNull);
    });

    test('comment_type 缺失或 0 → null（不猜成 17）', () {
      expect(BiliContentParser.commentEntryOf(detailItem(commentType: null)), isNull);
      expect(BiliContentParser.commentEntryOf(detailItem(commentType: 0)), isNull);
    });

    test('basic 整段缺失 → null，不崩', () {
      final raw = detailItem()..remove('basic');
      expect(BiliContentParser.commentEntryOf(raw), isNull);
    });

    test('非 Map 输入 → null，不崩', () {
      expect(BiliContentParser.commentEntryOf(null), isNull);
      expect(BiliContentParser.commentEntryOf('x'), isNull);
      expect(BiliContentParser.commentEntryOf(<Object>[]), isNull);
    });

    test('旧字段名 comment_id 也能兜底', () {
      final raw = detailItem()..remove('basic');
      raw['basic'] = <String, dynamic>{
        'comment_id': '999',
        'comment_type': 11,
      };
      expect(BiliContentParser.commentEntryOf(raw)!.oid, '999');
    });
  });

  group('fromDynamicDetail：复用动态解析', () {
    test('能产出 ContentItem，且 id 稳定', () {
      final item = BiliContentParser.fromDynamicDetail(
        detailItem(),
        sub: BiliTimelineSource.followingSubscription,
        fetchedAt: DateTime.utc(2026, 11, 2),
      );

      expect(item, isNotNull);
      expect(item!.authorName, '某位 UP');
      expect(item.summary, '动态正文');
      // 与时间线卡片走同一个 id 算法，才能「同一条动态在别处也不重复」。
      final again = BiliContentParser.fromDynamicDetail(
        detailItem(),
        sub: BiliTimelineSource.followingSubscription,
        fetchedAt: DateTime.utc(2026, 11, 3),
      );
      expect(again!.id, item.id);
    });

    test('没有可展示内容时返回 null（与 feed 侧一致）', () {
      final empty = <String, dynamic>{
        'id_str': '111',
        'type': 'DYNAMIC_TYPE_DRAW',
        'basic': <String, dynamic>{'comment_id_str': '1', 'comment_type': 11},
        'modules': <String, dynamic>{
          'module_author': <String, dynamic>{'name': 'x', 'mid': 1},
          'module_dynamic': <String, dynamic>{},
        },
      };
      expect(
        BiliContentParser.fromDynamicDetail(
          empty,
          sub: BiliTimelineSource.followingSubscription,
          fetchedAt: DateTime.utc(2026, 11, 2),
        ),
        isNull,
      );
    });
  });
}
