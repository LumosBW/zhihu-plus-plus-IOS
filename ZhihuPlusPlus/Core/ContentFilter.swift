import Foundation

/// 本地内容过滤，规则对应 Android 版 `Feed.kt` 的质量过滤与 `ContentFilterExtensions.kt`。
@MainActor
enum ContentFilter {
    struct Options {
        var quality: Bool
        var keywords: Bool = true
        var users: Bool = true
        var paid: Bool = true
    }

    static func reason(for target: FeedTarget, options: Options) -> String? {
        let settings = AppSettings.shared
        if options.users, let authorID = target.author?.id,
           let blocked = settings.blockedUsers.first(where: { $0.id == authorID }) {
            return "已屏蔽用户：\(blocked.name)"
        }
        if options.paid, settings.blockPaidContent, target.isPaid {
            return "知乎盐选付费内容"
        }
        if options.keywords {
            let haystack = (target.title + "\n" + target.excerpt).lowercased()
            if let keyword = settings.blockedKeywords.first(where: { haystack.contains($0.lowercased()) }) {
                return "屏蔽词：\(keyword)"
            }
        }
        if options.quality, settings.qualityFilter {
            return qualityReason(for: target)
        }
        return nil
    }

    private static func qualityReason(for target: FeedTarget) -> String? {
        let following = target.author?.isFollowing ?? false
        switch target.kind {
        case .answer:
            if target.voteupCount >= 0, target.voteupCount < 10, target.author != nil, !following {
                return "规则：回答；赞数 < 10，未关注作者"
            }
        case .article:
            let followers = target.author?.followerCount ?? 0
            if (followers < 50 || target.voteupCount < 20), !following {
                return "规则：文章；作者粉丝数 < 50 或文章赞数 < 20，未关注作者"
            }
        case .zvideo:
            let followers = target.author?.followerCount ?? 0
            if followers < 50, target.voteupCount < 20, !following {
                return "规则：视频；作者粉丝数 < 50 且赞数 < 20"
            }
        case .question:
            if target.answerCount < 5, target.followerCount < 50 {
                return "规则：问题；回答数 < 5，关注数 < 50"
            }
        default:
            break
        }
        return nil
    }

    /// 标记过滤原因；不显示占位时直接移除。
    static func apply(_ items: [FeedItem], options: Options) -> [FeedItem] {
        let showPlaceholder = AppSettings.shared.showFilteredPlaceholder
        return items.compactMap { item in
            guard let reason = reason(for: item.target, options: options) else { return item }
            guard showPlaceholder else { return nil }
            var filtered = item
            filtered.filterReason = reason
            return filtered
        }
    }
}
