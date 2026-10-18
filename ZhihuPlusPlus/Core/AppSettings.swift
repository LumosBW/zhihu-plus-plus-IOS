import Foundation
import Observation

/// 首页推荐来源，与 Android 版 `RecommendationMode` 的 WEB / ANDROID 对应：两者请求同一个地址，
/// 区别只在于请求身份，知乎据此返回不同算法的推荐流。
enum RecommendationSource: String, CaseIterable, Identifiable {
    case web = "server"
    case android

    var id: String { rawValue }

    /// 首页标签上的短名。
    var label: String {
        switch self {
        case .web: return "推荐"
        case .android: return "发现"
        }
    }

    /// 设置页里的说明，讲清楚两个标签各自用的是哪套推荐算法。
    var detail: String {
        switch self {
        case .web: return "知乎网页版的推荐算法"
        case .android: return "知乎 App 的推荐算法，内容更偏热门"
        }
    }

    static let url = "https://api.zhihu.com/topstory/recommend"

    /// 安卓端以官方安卓 App 身份请求，返回 `ComponentCard` 卡片；Web 端为 nil，按网页身份签名请求。
    var appHeaders: [String: String]? {
        self == .android ? ZhihuClient.androidAppHeaders : nil
    }
}

struct BlockedUser: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}

/// 用户偏好，对应 Android 版的屏蔽词 / 屏蔽用户 / 质量过滤 / 盐选屏蔽等设置。
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var recommendationSource: RecommendationSource {
        didSet { defaults.set(recommendationSource.rawValue, forKey: "recommendationSource") }
    }

    /// 首页质量过滤（低赞且未关注作者的内容）。
    var qualityFilter: Bool {
        didSet { defaults.set(qualityFilter, forKey: "qualityFilter") }
    }

    /// 屏蔽知乎盐选付费内容。
    var blockPaidContent: Bool {
        didSet { defaults.set(blockPaidContent, forKey: "blockPaidContent") }
    }

    /// 被过滤的内容是否以“已屏蔽”占位显示（否则直接隐藏）。
    var showFilteredPlaceholder: Bool {
        didSet { defaults.set(showFilteredPlaceholder, forKey: "showFilteredPlaceholder") }
    }

    var blockedKeywords: [String] {
        didSet { defaults.set(blockedKeywords, forKey: "blockedKeywords") }
    }

    var blockedUsers: [BlockedUser] {
        didSet { defaults.set(try? JSONEncoder().encode(blockedUsers), forKey: "blockedUsers") }
    }

    /// 正文字号（px）。
    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: "fontSize") }
    }

    private init() {
        recommendationSource = RecommendationSource(rawValue: defaults.string(forKey: "recommendationSource") ?? "") ?? .web
        qualityFilter = defaults.object(forKey: "qualityFilter") as? Bool ?? true
        blockPaidContent = defaults.object(forKey: "blockPaidContent") as? Bool ?? true
        showFilteredPlaceholder = defaults.object(forKey: "showFilteredPlaceholder") as? Bool ?? false
        blockedKeywords = defaults.stringArray(forKey: "blockedKeywords") ?? []
        if let data = defaults.data(forKey: "blockedUsers"),
           let users = try? JSONDecoder().decode([BlockedUser].self, from: data) {
            blockedUsers = users
        } else {
            blockedUsers = []
        }
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 17
    }

    func blockUser(id: String, name: String) {
        guard !id.isEmpty, !blockedUsers.contains(where: { $0.id == id }) else { return }
        blockedUsers.append(BlockedUser(id: id, name: name))
    }

    func addKeyword(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !blockedKeywords.contains(trimmed) else { return }
        blockedKeywords.append(trimmed)
    }
}
