import Foundation

/// 知乎接口集合，地址与 include 参数取自 Android 版各 ViewModel。
enum ZhihuAPI {
    static var client: ZhihuClient { .shared }

    static let feedInclude = "data[*].content,excerpt,headline,target.author.badge_v2"
    static let answerInclude = "content,paid_info,can_comment,excerpt,thanks_count,voteup_count,comment_count,visited_count,reaction,ip_info,relationship.voting,relationship.is_favorited,question.author,favlists_count,created_time,updated_time"
    static let articleInclude = "content,paid_info,can_comment,excerpt,thanks_count,voteup_count,comment_count,visited_count,relationship,ip_info,relationship.vote,relationship.is_favorited,favlists_count,created,updated"
    static let questionInclude = "read_count,visit_count,answer_count,voteup_count,comment_count,follower_count,detail,excerpt,author,relationship.is_following,topics"
    static let memberInclude = "follower_count,following_count,answer_count,articles_count,voteup_count,description,headline,is_following,ip_info,cover_url,avatar_url_template"

    // MARK: 列表地址

    static let hotListURL = "https://www.zhihu.com/api/v3/feed/topstory/hot-lists/total?limit=50&mobile=true"

    static func questionFeedsURL(_ id: String, order: String) -> String {
        "https://www.zhihu.com/api/v4/questions/\(id)/feeds?limit=20&order=\(order)"
    }

    static func rootCommentsURL(kind: ContentKind, id: String, order: String) -> String {
        "https://www.zhihu.com/api/v4/comment_v5/\(kind.commentResource)/\(id)/root_comment?order_by=\(order)"
    }

    static func childCommentsURL(_ commentID: String) -> String {
        "https://www.zhihu.com/api/v4/comment_v5/comment/\(commentID)/child_comment"
    }

    static func memberContentURL(_ token: String, kind: ContentKind) -> String {
        let resource = kind == .article ? "articles" : "answers"
        return "https://www.zhihu.com/api/v4/members/\(token)/\(resource)?sort_by=created"
    }

    static func searchURL(_ query: String) -> String {
        let params: [(String, String)] = [
            ("gk_version", "gz-gaokao"),
            ("t", "general"),
            ("q", query),
            ("correction", "1"),
            ("offset", "0"),
            ("limit", "20"),
            ("search_source", "Normal"),
            ("show_all_topics", "0"),
        ]
        let query = params.map { "\($0.0)=\(ZhihuClient.percentEncode($0.1))" }.joined(separator: "&")
        return "https://www.zhihu.com/api/v4/search_v3?\(query)"
    }

    // MARK: 详情

    static func contentDetail(kind: ContentKind, id: String) async throws -> ContentDetail {
        let json: JSONValue
        switch kind {
        case .answer:
            json = try await client.json(.get, "https://www.zhihu.com/api/v4/answers/\(id)", include: answerInclude)
        case .article:
            json = try await client.json(.get, "https://www.zhihu.com/api/v4/articles/\(id)", include: articleInclude)
        default:
            throw ZhihuError(message: "不支持的内容类型")
        }
        return ContentDetail(kind: kind, json: json)
    }

    static func question(_ id: String) async throws -> QuestionDetail {
        QuestionDetail(json: try await client.json(.get, "https://www.zhihu.com/api/v4/questions/\(id)", include: questionInclude))
    }

    static func pin(_ id: String) async throws -> PinDetail {
        PinDetail(json: try await client.json(.get, "https://www.zhihu.com/api/v4/pins/\(id)", include: "topics"))
    }

    static func people(_ token: String) async throws -> PeopleProfile {
        PeopleProfile(json: try await client.json(.get, "https://www.zhihu.com/api/v4/members/\(token)", include: memberInclude))
    }

    static func hotSearch() async throws -> [String] {
        let json = try await client.json(.get, "https://www.zhihu.com/api/v4/search/hot_search")
        return json["hot_search_queries"].array.compactMap { $0["query"].nonEmptyString }
    }

    // MARK: 互动

    /// 赞同 / 取消赞同，返回最新赞同数。
    static func vote(kind: ContentKind, id: String, state: VoteState) async throws -> Int? {
        let json: JSONValue
        switch kind {
        case .answer:
            let type: String
            switch state {
            case .up: type = "up"
            case .down: type = "down"
            case .neutral: type = "neutral"
            }
            json = try await client.json(.post, "https://www.zhihu.com/api/v4/answers/\(id)/voters", json: ["type": type])
        case .article:
            json = try await client.json(.post, "https://www.zhihu.com/api/v4/articles/\(id)/voters", json: ["voting": state == .up ? 1 : 0])
        default:
            return nil
        }
        return json["voteup_count"].int
    }

    static func followQuestion(_ id: String, follow: Bool) async throws {
        _ = try await client.json(follow ? .post : .delete, "https://www.zhihu.com/api/v4/questions/\(id)/followers")
    }

    static func followMember(_ token: String, follow: Bool) async throws {
        _ = try await client.json(follow ? .post : .delete, "https://www.zhihu.com/api/v4/members/\(token)/followers")
    }

    // MARK: 收藏（地址与请求方式同 Android 版 ArticleViewModel）

    static func favoriteFolders(kind: ContentKind, id: String) async throws -> [FavoriteFolder] {
        let json = try await client.json(.get, "https://api.zhihu.com/collections/contents/\(kind.rawValue)/\(id)?limit=50")
        return json["data"].array.compactMap(FavoriteFolder.init(json:))
    }

    static func setFavorite(kind: ContentKind, id: String, folderID: String, add: Bool) async throws {
        _ = try await client.json(
            .put,
            "https://api.zhihu.com/collections/contents/\(kind.rawValue)/\(id)",
            form: [add ? "add_collections" : "remove_collections": folderID]
        )
    }

    static func createFavoriteFolder(title: String, isPublic: Bool) async throws {
        _ = try await client.json(
            .post,
            "https://www.zhihu.com/api/v4/collections",
            json: ["title": title, "description": "", "is_public": isPublic]
        )
    }

    static func likeComment(_ id: String, like: Bool) async throws {
        _ = try await client.json(like ? .post : .delete, "https://www.zhihu.com/api/v4/comments/\(id)/like")
    }

    static func postComment(kind: ContentKind, id: String, text: String, replyTo: String?) async throws -> Comment? {
        var body: [String: Any] = ["content": "<p>\(HTML.escape(text))</p>"]
        if let replyTo {
            body["reply_comment_id"] = replyTo
        }
        let json = try await client.json(
            .post,
            "https://www.zhihu.com/api/v4/comment_v5/\(kind.commentResource)/\(id)/comment",
            json: body
        )
        return Comment(json: json)
    }

    // MARK: 日报

    /// `topStories` 是首页轮播的大图头条，只有最新一天返回。
    static func dailyStories(before date: String?) async throws -> (date: String, stories: [DailyStory], topStories: [DailyStory]) {
        let path = date.map { "/before/\($0)" } ?? "/latest"
        let json: JSONValue
        do {
            json = try await client.json(.get, "https://news-at.zhihu.com/api/4/stories\(path)")
        } catch let error as URLError where error.code == .cannotFindHost || error.code == .dnsLookupFailed {
            // 部分海外网络无法解析 news-at，Android 版同样只在 DNS 失败时回退到 daily 域名。
            json = try await client.json(.get, "https://daily.zhihu.com/api/4/stories\(path)")
        }
        return (
            json["date"].stringValue,
            json["stories"].array.compactMap(DailyStory.init(json:)),
            json["top_stories"].array.compactMap(DailyStory.init(json:))
        )
    }

    /// 日报文章大多是知乎回答的转载，从正文中找出原文链接。
    static func dailyStoryOrigin(_ id: String) async throws -> (route: Route?, body: String, css: [String]) {
        let json = try await client.json(.get, "https://daily.zhihu.com/api/7/story/\(id)")
        let body = json["body"].stringValue
        let css = json["css"].array.compactMap(\.nonEmptyString)
        let patterns = [
            "<a[^>]*class=\"originUrl\"[^>]*href=\"([^\"]+)\"",
            "<a[^>]*href=\"([^\"]+)\"[^>]*class=\"originUrl\"",
            "<div class=\"view-more\">\\s*<a[^>]*href=\"([^\"]+)\"",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let range = Range(match.range(at: 1), in: body),
                  let url = URL(string: HTML.decodeEntities(String(body[range]))),
                  let route = LinkResolver.route(for: url) else { continue }
            return (route, body, css)
        }
        return (nil, body, css)
    }
}
