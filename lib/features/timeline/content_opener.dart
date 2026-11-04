import 'package:flutter/material.dart';

import '../../data/models/content_item.dart';
import '../player/player_page.dart';
import 'content_detail_page.dart';

/// 「点开一条内容」的**唯一**分发点。
///
/// ## 为什么会存在这个文件
///
/// 真机反馈：转发的视频动态点封面只显示一张照片，也没有评论。
/// 根因是**分发逻辑散落在两处、规则还不一致**：
///
/// | 入口 | 当时的行为 |
/// | --- | --- |
/// | 时间线卡片整卡点击（`timeline_page._openItem`） | B 站 + 有 bvid → `PlayerPage`（能播、有评论） |
/// | 卡片里的原动态块（`content_card._openOrigin`） | **一律** `ContentDetailPage` |
///
/// 于是同一条 B 站视频，从时间线点进去能播，从转发块点进去却只看到
/// 封面大图 + 「接口没有给出评论入口」——两个入口两套行为。
///
/// 修法不是给 `_openOrigin` 补一个 `if`（那只是把两份逻辑变成三份），
/// 而是**把规则收敛到这一个函数**：所有「打开某条内容」的调用方都走它，
/// 规则只写一遍。
///
/// ## 分发规则
///
/// ```
/// B 站 + 有 bvid  → PlayerPage        （能播放，自带 aid 评论区）
/// 其余            → ContentDetailPage （图文 / 微博视频：封面即播 + 评论列表）
/// ```
///
/// ## 微博视频为什么**不再**单独进播放页（2026-10-27 修订）
///
/// 上一轮曾让「微博 + 有直链」直接压 `SimpleVideoPage`，理由是「点封面就是想看视频」。
/// 真机反馈否掉了这个判断：
///
/// > 「点击视频的时候进的是视频详情页，能看到评论的那种……还没办法对其进行操作。」
///
/// 全屏播放页只有画面，**没有评论、没有原文、没有转发块**，用户看完想评论必须
/// 返回时间线再点一次。所以微博视频回到 `ContentDetailPage`：视频在页内自动播放，
/// 评论就在它下面（`_CommentSection` 已接 `hotflow`）。
class ContentOpener {
  ContentOpener._();

  /// 是否需要走 [PlayerPage]（B 站可播视频）。
  ///
  /// 判定只认 `platform == bilibili && videoRef.bvid` 非空：
  /// - 不看 `kind`：B 站「转发了一条视频」的 kind 可能是 repost，
  ///   但只要它带着 bvid，播放页就是正确去处；
  /// - 不看 `isPlayable`：那个 getter 对微博也返回 true，
  ///   而微博进不了 [PlayerPage]。
  static bool opensInPlayer(ContentItem item) {
    if (item.platform != Platform.bilibili) return false;
    final String? bvid = item.videoRef?.bvid;
    return bvid != null && bvid.isNotEmpty;
  }

  /// 打开一条内容。
  ///
  /// [headerLabel] 只在落到 [ContentDetailPage] 时生效（例如「原动态」），
  /// 进播放页时忽略 —— 播放页的标题来自视频信息本身。
  static Future<void> open(
    BuildContext context,
    ContentItem item, {
    String? headerLabel,
  }) {
    final NavigatorState navigator = Navigator.of(context);
    if (opensInPlayer(item)) {
      return navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            bvid: item.videoRef!.bvid!,
            aid: item.videoRef?.aid,
            page: item.videoRef?.page ?? 1,
            fallbackTitle: item.displayTitle,
          ),
        ),
      );
    }

    return navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => ContentDetailPage(
          item: item,
          headerLabel: headerLabel,
        ),
      ),
    );
  }
}
