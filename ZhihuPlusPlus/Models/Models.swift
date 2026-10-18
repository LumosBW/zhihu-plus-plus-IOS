import Foundation

enum ContentKind: String, Hashable {
    case answer
    case article
    case question
    case pin
    case zvideo
    case unknown

    var label: String {
        switch self {
        case .answer: return "回答"
        case .article: return "文章"
        case .question: return "问题"
        case .pin: return "想法"
        case .zvideo: return "视频"
        case .unknown: return "内容"
        }
    }

    /// comment_v5 接口中使用的资源复数名。
    var commentResource: String {
        switch self {
        case .answer: return "answers"
        case .article: return "articles"
        case .question: return "questions"
        case .pin: return "pins"
        case .zvideo: return "zvideos"
        case .unknown: return "answers"
        }
    }
}

struct Author: Hashable, Identifiable {
    var id: String
    var name: String
    var headline: String
    var avatarURL: URL?
    var urlToken: String?
    var followerCount: Int
    var isFollowing: Bool
    /// 认证徽章（图标 + 说明，如“优秀答主”“北京大学 计算机科学博士”），规则同 Android 版 `officialBadge()`。
    var badgeIcon: URL?
    var badgeText: String?

    init?(json: JSONValue) {
        guard json.object != nil else { return nil }
        id = json["id"].stringValue
        name = HTML.plainText(json["name"].stringValue)
        headline = HTML.plainText(json["headline"].stringValue)
        avatarURL = json["avatar_url"].nonEmptyString.flatMap(URL.init(string:))
        urlToken = json["url_token"].nonEmptyString
        followerCount = json["follower_count"].int ?? json["followers_count"].intValue
        isFollowing = json["is_following"].boolValue
        let badgeV2 = json["badge_v2"]
        let details = (badgeV2["detail_badges"].array.isEmpty ? badgeV2["merged_badges"] : badgeV2["detail_badges"]).array
            .filter { ($0["badge_status"].string ?? "passed") == "passed" && $0["title"].nonEmptyString != nil }
        let primary = details.first { $0["type"].string != "identity" && $0["icon"].nonEmptyString != nil }
            ?? details.first { $0["icon"].nonEmptyString != nil }
        if let primary {
            badgeIcon = (badgeV2["icon"].nonEmptyString ?? primary["icon"].nonEmptyString).flatMap(URL.init(string:))
            badgeText = primary["description"].nonEmptyString ?? primary["title"].nonEmptyString
        }
    }

    init(id: String, name: String, headline: String = "", avatarURL: URL? = nil, urlToken: String? = nil) {
        self.id = id
        self.name = name
        self.headline = headline
        self.avatarURL = avatarURL
        self.urlToken = urlToken
        followerCount = 0
        isFollowing = false
    }

    /// 匿名用户的 id 为 "0"，没有个人主页。
    var profileKey: String? {
        if let urlToken { return urlToken }
        return id.isEmpty || id == "0" ? nil : id
    }
}

/// 列表中的一条内容（回答 / 文章 / 问题 / 想法 / 视频），对应 Android 版 `Feed.Target`。
struct FeedTarget: Hashable, Identifiable {
    var kind: ContentKind
    var id: String
    var title: String
    var excerpt: String
    var author: Author?
    var voteupCount: Int
    var commentCount: Int
    var answerCount: Int
    var followerCount: Int
    var questionID: String?
    var questionAuthorID: String?
    var thumbnail: URL?
    var isPaid: Bool
    var createdTime: Int
    var url: String

    init?(json: JSONValue) {
        guard let type = json["type"].string else { return nil }
        let kind = ContentKind(rawValue: type) ?? .unknown
        guard kind != .unknown, let id = json["id"].nonEmptyString else { return nil }
        self.kind = kind
        self.id = id
        author = Author(json: json["author"])
        voteupCount = json["voteup_count"].int ?? json["vote_count"].int ?? json["like_count"].intValue
        commentCount = json["comment_count"].intValue
        answerCount = json["answer_count"].intValue
        followerCount = json["follower_count"].intValue
        thumbnail = (json["thumbnail"].nonEmptyString ?? json["thumbnails"][0].nonEmptyString).flatMap(URL.init(string:))
        createdTime = json["created_time"].int ?? json["created"].intValue
        url = json["url"].stringValue

        let excerptSource = json["excerpt"].nonEmptyString
            ?? json["excerpt_new"].nonEmptyString
            ?? json["description"].nonEmptyString
            ?? json["excerpt_title"].nonEmptyString
            ?? ""

        switch kind {
        case .answer:
            let question = json["question"]
            title = question["title"].nonEmptyString ?? question["name"].nonEmptyString ?? ""
            questionID = question["id"].nonEmptyString
            questionAuthorID = question["author"]["id"].nonEmptyString
        case .question:
            title = json["title"].nonEmptyString ?? json["name"].nonEmptyString ?? ""
            questionID = id
            questionAuthorID = json["author"]["id"].nonEmptyString
        case .pin:
            let text = json["content"].array.first { $0["type"].string == "text" }
            title = text?["title"].nonEmptyString ?? ""
        default:
            title = json["title"].stringValue
        }
        title = HTML.plainText(title)

        var summary = HTML.plainText(excerptSource)
        if kind == .pin, summary.isEmpty {
            let text = json["content"].array.first { $0["type"].string == "text" }
            summary = HTML.plainText(text?["content"].stringValue ?? json["content_html"].stringValue)
        }
        excerpt = summary == title ? "" : summary

        isPaid = json["paid_info"].object != nil
            || json["answer_type"].string == "paid"
            || json["is_paid"].boolValue
    }

    init(kind: ContentKind, id: String, title: String) {
        self.kind = kind
        self.id = id
        self.title = title
        excerpt = ""
        voteupCount = 0
        commentCount = 0
        answerCount = 0
        followerCount = 0
        isPaid = false
        createdTime = 0
        url = ""
    }

    var route: Route? {
        switch kind {
        case .answer: return .answer(id)
        case .article: return .article(id)
        case .question: return .question(id)
        case .pin: return .pin(id)
        case .zvideo: return URL(string: "https://www.zhihu.com/zvideo/\(id)").map(Route.web)
        case .unknown: return nil
        }
    }

    var statsText: String {
        switch kind {
        case .answer, .article, .zvideo:
            return "\(Format.count(voteupCount)) 赞同 · \(Format.count(commentCount)) 评论"
        case .pin:
            return "\(Format.count(voteupCount)) 赞 · \(Format.count(commentCount)) 评论"
        case .question:
            return "\(Format.count(followerCount)) 关注 · \(Format.count(answerCount)) 回答"
        case .unknown:
            return ""
        }
    }

    var shareURL: URL? {
        switch kind {
        case .answer:
            if let questionID { return URL(string: "https://www.zhihu.com/question/\(questionID)/answer/\(id)") }
            return URL(string: "https://www.zhihu.com/answer/\(id)")
        case .article: return URL(string: "https://zhuanlan.zhihu.com/p/\(id)")
        case .question: return URL(string: "https://www.zhihu.com/question/\(id)")
        case .pin: return URL(string: "https://www.zhihu.com/pin/\(id)")
        case .zvideo: return URL(string: "https://www.zhihu.com/zvideo/\(id)")
        case .unknown: return nil
        }
    }
}

struct FeedItem: Hashable, Identifiable {
    var target: FeedTarget
    /// 来源说明，例如“XXX 赞同了回答”。
    var actionText: String?
    /// 热榜的热度文本。
    var metricText: String?
    var filterReason: String?

    var id: String { "\(target.kind.rawValue):\(target.id)" }
}

enum FeedParser {
    /// 解析推荐、关注、热榜、问题回答列表、个人主页等接口返回的 `data` 数组。
    static func items(from data: [JSONValue]) -> [FeedItem] {
        var result: [FeedItem] = []
        for entry in data {
            result.append(contentsOf: items(fromEntry: entry))
        }
        return result
    }

    private static func items(fromEntry entry: JSONValue) -> [FeedItem] {
        let type = entry["type"].stringValue
        switch type {
        case "feed_advert":
            return []
        case "feed_group":
            return entry["list"].array.flatMap(items(fromEntry:))
        case "hot_list_feed":
            guard var target = FeedTarget(json: entry["target"]) else { return [] }
            if target.thumbnail == nil {
                target.thumbnail = entry["children"].array.first?["thumbnail"].nonEmptyString.flatMap(URL.init(string:))
            }
            return [FeedItem(target: target, metricText: entry["detail_text"].nonEmptyString)]
        case "ComponentCard":
            return componentCard(entry).map { [$0] } ?? []
        case "feed", "moments_feed", "topic_feed", "feed_item_index_group", "question_feed_card", "search_result":
            let targetJSON = entry["target"].exists ? entry["target"] : entry["object"]
            // 推广内容（软文）带有 promotion_extra，与 Android 版一致直接过滤。
            if entry["promotion_extra"].nonEmptyString != nil { return [] }
            guard let target = FeedTarget(json: targetJSON) else { return [] }
            let action = entry["action_text"].nonEmptyString
                ?? entry["moment_desc"].nonEmptyString
                ?? entry["target_description"].nonEmptyString
            return [FeedItem(target: target, actionText: action.map(HTML.plainText))]
        default:
            // 个人主页、收藏夹等接口直接返回内容对象。
            if let target = FeedTarget(json: entry) {
                return [FeedItem(target: target)]
            }
            if let target = FeedTarget(json: entry["content"]) {
                return [FeedItem(target: target)]
            }
            return []
        }
    }
}

extension FeedParser {
    /// 安卓端推荐（官方安卓 App 身份）返回的 `ComponentCard` 卡片，对应 Android 版 `parseMobileHomeFeedDisplayItem`。
    static func componentCard(_ card: JSONValue) -> FeedItem? {
        guard let parameter = card["action"]["parameter"].string,
              let range = parameter.range(of: "route_url=") else { return nil }
        let routeString = String(parameter[range.upperBound...]).removingPercentEncoding ?? ""
        guard let url = URL(string: routeString), let route = LinkResolver.route(for: url) else { return nil }
        let kind: ContentKind
        let id: String
        switch route {
        case .answer(let value): (kind, id) = (.answer, value)
        case .article(let value): (kind, id) = (.article, value)
        case .question(let value): (kind, id) = (.question, value)
        case .pin(let value): (kind, id) = (.pin, value)
        default: return nil
        }
        let children = card["children"].array
        let title = children.first { $0["id"].string == "Text" }?["text"].stringValue ?? ""
        let summary = children.first { $0["id"].string == "text_pin_summary" }?["text"].stringValue ?? ""
        let lines = children.filter { $0["type"].string == "Line" }
        let authorLine = lines.first {
            let style = $0["style"].stringValue
            return style.hasPrefix("RecommendAuthorLine") || style.hasPrefix("LineAuthor_default")
        }?["elements"].array ?? []
        let authorName = authorLine.first { $0["type"].string == "Text" }?["text"].string
        let avatar = authorLine.first { $0["style"].string == "Avatar_default" }?["image"]["url"].nonEmptyString
        let footer = lines.count > 1 ? lines[1]["elements"].array : []
        let reactionCount = { (reaction: String) in footer.first { $0["reaction"].string == reaction }?["count"].int }

        var target = FeedTarget(kind: kind, id: id, title: HTML.plainText(title))
        target.excerpt = HTML.plainText(summary)
        if let authorName {
            target.author = Author(id: "", name: authorName, avatarURL: avatar.flatMap(URL.init(string:)))
        }
        var item = FeedItem(target: target)
        if let votes = reactionCount("Vote"), let comments = reactionCount("Comment") {
            item.target.voteupCount = votes
            item.target.commentCount = comments
        } else {
            // 现在的卡片底栏多为一段现成文字（“2026 赞同 · 55 评论”），没有分项计数，直接展示。
            item.metricText = footer.first { $0["type"].string == "Text" }?["text"].nonEmptyString
        }
        return item
    }
}

enum VoteState: Hashable {
    case up
    case neutral
    case down
}

/// 回答 / 文章正文详情。
struct ContentDetail: Hashable, Identifiable {
    var kind: ContentKind
    var id: String
    var title: String
    var html: String
    var author: Author?
    var voteupCount: Int
    var commentCount: Int
    var favoriteCount: Int
    var createdTime: Int
    var updatedTime: Int
    var questionID: String?
    /// 回答所属问题的回答数与关注数，用于正文标题下的问题入口。
    var questionAnswerCount: Int?
    var questionFollowerCount: Int?
    var voteState: VoteState
    /// 是否已收藏到任一收藏夹；接口没返回时为 nil，打开收藏面板后会更新。
    var isFavorited: Bool?
    var ipInfo: String?
    var isPaid: Bool
    var titleImage: URL?

    init(kind: ContentKind, json: JSONValue) {
        self.kind = kind
        id = json["id"].stringValue
        author = Author(json: json["author"])
        voteupCount = json["voteup_count"].intValue
        commentCount = json["comment_count"].intValue
        favoriteCount = json["favlists_count"].int ?? json["favorite_count"].intValue
        createdTime = json["created_time"].int ?? json["created"].intValue
        updatedTime = json["updated_time"].int ?? json["updated"].intValue
        ipInfo = json["ip_info"].nonEmptyString
        isPaid = json["paid_info"].object != nil
        html = json["content"].stringValue
        titleImage = json["title_image"].nonEmptyString.flatMap(URL.init(string:))
        if kind == .answer {
            title = HTML.plainText(json["question"]["title"].stringValue)
            questionID = json["question"]["id"].nonEmptyString
        } else {
            title = HTML.plainText(json["title"].stringValue)
            questionID = nil
        }
        let voting = json["relationship"]["voting"].int
            ?? json["reaction"]["relation"]["vote"].string.map { $0.uppercased() == "UP" ? 1 : ($0.uppercased() == "DOWN" ? -1 : 0) }
            ?? 0
        voteState = voting > 0 ? .up : (voting < 0 ? .down : .neutral)
        isFavorited = json["relationship"]["is_favorited"].bool
    }

    var shareURL: URL? {
        switch kind {
        case .answer:
            if let questionID { return URL(string: "https://www.zhihu.com/question/\(questionID)/answer/\(id)") }
            return URL(string: "https://www.zhihu.com/answer/\(id)")
        case .article:
            return URL(string: "https://zhuanlan.zhihu.com/p/\(id)")
        default:
            return nil
        }
    }
}

struct QuestionDetail: Hashable {
    var id: String
    var title: String
    var detailHTML: String
    var answerCount: Int
    var followerCount: Int
    var visitCount: Int
    var commentCount: Int
    var isFollowing: Bool
    var topics: [String]
    var author: Author?

    init(json: JSONValue) {
        id = json["id"].stringValue
        title = HTML.plainText(json["title"].stringValue)
        detailHTML = json["detail"].stringValue
        answerCount = json["answer_count"].intValue
        followerCount = json["follower_count"].intValue
        visitCount = json["visit_count"].int ?? json["read_count"].intValue
        commentCount = json["comment_count"].intValue
        isFollowing = json["relationship"]["is_following"].boolValue
        topics = json["topics"].array.compactMap { $0["name"].nonEmptyString }
        author = Author(json: json["author"])
    }
}

struct PinDetail: Hashable {
    var id: String
    var html: String
    var author: Author?
    var likeCount: Int
    var commentCount: Int
    var createdTime: Int

    init(json: JSONValue) {
        id = json["id"].stringValue
        author = Author(json: json["author"])
        likeCount = json["like_count"].int ?? json["reaction_count"].intValue
        commentCount = json["comment_count"].intValue
        createdTime = json["created"].int ?? json["created_time"].intValue

        // content 数组比 content_html 更完整（含图片原图地址），优先用它拼出正文。
        var parts: [String] = []
        for item in json["content"].array {
            switch item["type"].stringValue {
            case "text":
                parts.append(item["content"].stringValue)
            case "image":
                let src = item["url"].stringValue
                let original = item["original_url"].nonEmptyString ?? src
                parts.append("<figure><img src=\"\(HTML.escape(src))\" data-original=\"\(HTML.escape(original))\"></figure>")
            case "link_card":
                let url = item["url"].stringValue
                let title = item["title"].nonEmptyString ?? url
                parts.append("<p><a href=\"\(HTML.escape(url))\">🔗 \(HTML.escape(title))</a></p>")
            case "video":
                parts.append("<p>[视频] 请在浏览器中查看</p>")
            default:
                break
            }
        }
        html = parts.isEmpty ? json["content_html"].stringValue : parts.joined(separator: "\n")
        if let origin = json["origin_pin"].object {
            let originPin = PinDetail(json: JSONValue(origin))
            html += "<blockquote><p><b>\(HTML.escape(originPin.author?.name ?? "")):</b></p>\(originPin.html)</blockquote>"
        }
    }
}

struct Comment: Hashable, Identifiable {
    var id: String
    var text: String
    var author: Author?
    var replyToName: String?
    var likeCount: Int
    var liked: Bool
    var createdTime: Int
    var childCommentCount: Int
    var childComments: [Comment]
    var isAuthor: Bool
    /// 评论者 / 被回复者的身份标签（如“作者”），取自 author_tag / reply_author_tag，同 Android 版。
    var authorTag: String?
    var replyToTag: String?
    var ipText: String?
    /// 评论附带的图片、动图或表情包，知乎以 `<a class="comment_img|comment_gif|comment_sticker" href>` 放在正文里。
    var imageURL: URL?

    init?(json: JSONValue) {
        guard let id = json["id"].nonEmptyString else { return nil }
        self.id = id
        var content = json["content"].stringValue
        let imageAnchor = try! NSRegularExpression(
            pattern: "<a\\b[^>]*class=\"[^\"]*\\bcomment_(?:img|gif|sticker)\\b[^\"]*\"[^>]*>.*?</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        if let match = imageAnchor.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let anchorRange = Range(match.range, in: content),
           let hrefRange = content[anchorRange].range(of: "href=\"[^\"]+\"", options: .regularExpression) {
            let href = content[hrefRange].dropFirst("href=\"".count).dropLast()
            imageURL = URL(string: HTML.decodeEntities(String(href)))
        }
        // 图片链接的文字只是“[图片]”“[表情]”占位，图片单独展示后从正文里去掉。
        content = imageAnchor.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "")
        text = HTML.plainText(content)
        author = Author(json: json["author"])
        replyToName = json["reply_to_author"]["name"].nonEmptyString
        likeCount = json["like_count"].intValue
        liked = json["liked"].boolValue
        createdTime = json["created_time"].intValue
        childCommentCount = json["child_comment_count"].intValue
        childComments = json["child_comments"].array.compactMap(Comment.init(json:))
        isAuthor = json["is_author"].boolValue
        authorTag = json["author_tag"][0]["text"].nonEmptyString ?? (isAuthor ? "作者" : nil)
        replyToTag = json["reply_author_tag"][0]["text"].nonEmptyString
        ipText = json["comment_tag"].array.first { $0["type"].string == "ip_info" }?["text"].nonEmptyString
    }
}

struct PeopleProfile: Hashable {
    var id: String
    var urlToken: String
    var name: String
    var headline: String
    var description: String
    var avatarURL: URL?
    var coverURL: URL?
    var followerCount: Int
    var followingCount: Int
    var answerCount: Int
    var articleCount: Int
    var voteupCount: Int
    var isFollowing: Bool
    var ipInfo: String?

    init(json: JSONValue) {
        id = json["id"].stringValue
        urlToken = json["url_token"].stringValue
        name = json["name"].stringValue
        headline = HTML.plainText(json["headline"].stringValue)
        description = HTML.plainText(json["description"].stringValue)
        avatarURL = (json["avatar_url_template"].nonEmptyString?.replacingOccurrences(of: "{size}", with: "xl")
            ?? json["avatar_url"].nonEmptyString).flatMap(URL.init(string:))
        coverURL = json["cover_url"].nonEmptyString.flatMap(URL.init(string:))
        followerCount = json["follower_count"].intValue
        followingCount = json["following_count"].intValue
        answerCount = json["answer_count"].intValue
        articleCount = json["articles_count"].intValue
        voteupCount = json["voteup_count"].intValue
        isFollowing = json["is_following"].boolValue
        ipInfo = json["ip_info"].nonEmptyString
    }
}

struct DailyStory: Hashable, Identifiable {
    var id: String
    var title: String
    var hint: String
    var image: URL?
    var url: String

    init?(json: JSONValue) {
        guard let id = json["id"].nonEmptyString else { return nil }
        self.id = id
        title = json["title"].stringValue
        hint = json["hint"].stringValue
        // 头条（top_stories）带大图 image，普通条目只有缩略图 images。
        image = (json["image"].nonEmptyString ?? json["images"][0].nonEmptyString).flatMap(URL.init(string:))
        url = json["url"].stringValue
    }
}

/// 收藏面板里的收藏夹，`isFavorited` 表示当前内容是否在这个收藏夹里。
struct FavoriteFolder: Hashable, Identifiable {
    var id: String
    var title: String
    var isPublic: Bool
    var itemCount: Int
    var isFavorited: Bool

    init?(json: JSONValue) {
        guard let id = json["id"].nonEmptyString else { return nil }
        self.id = id
        title = json["title"].stringValue
        isPublic = json["is_public"].boolValue
        itemCount = json["item_count"].int ?? json["answer_count"].intValue
        isFavorited = json["is_favorited"].boolValue
    }
}

struct CollectionInfo: Hashable, Identifiable {
    var id: String
    var title: String
    var description: String
    var itemCount: Int
    var followerCount: Int
    var isPublic: Bool

    init?(json: JSONValue) {
        guard let id = json["id"].nonEmptyString else { return nil }
        self.id = id
        title = json["title"].stringValue
        description = HTML.plainText(json["description"].stringValue)
        itemCount = json["item_count"].int ?? json["answer_count"].intValue
        followerCount = json["follower_count"].intValue
        isPublic = json["is_public"].bool ?? true
    }
}

enum SearchResult: Hashable, Identifiable {
    case content(FeedItem)
    case people(Author)

    var id: String {
        switch self {
        case .content(let item): return item.id
        case .people(let author): return "people:\(author.id)"
        }
    }

    static func parse(_ data: [JSONValue]) -> [SearchResult] {
        data.compactMap { entry in
            guard entry["type"].string == "search_result" else { return nil }
            let object = entry["object"]
            if object["type"].string == "people" {
                return Author(json: object).map(SearchResult.people)
            }
            guard var target = FeedTarget(json: object) else { return nil }
            // 搜索结果的标题和摘要带 <em> 高亮标签，FeedTarget 已去除 HTML；
            // 部分回答没有 question.name，则使用高亮标题。
            if target.title.isEmpty {
                target.title = HTML.plainText(entry["highlight"]["title"].stringValue)
            }
            if target.excerpt.isEmpty {
                target.excerpt = HTML.plainText(entry["highlight"]["description"].stringValue)
            }
            return .content(FeedItem(target: target))
        }
    }
}
