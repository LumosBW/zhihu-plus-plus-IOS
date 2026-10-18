import Foundation
import Observation

/// 本机阅读记录的一条。
struct HistoryEntry: Codable, Hashable, Identifiable {
    var kind: String
    var contentID: String
    var title: String
    var excerpt: String
    var authorName: String?
    var avatarURL: URL?
    var readAt: Date

    var id: String { "\(kind):\(contentID)" }

    var contentKind: ContentKind { ContentKind(rawValue: kind) ?? .unknown }

    var route: Route? {
        switch contentKind {
        case .answer: return .answer(contentID)
        case .article: return .article(contentID)
        case .pin: return .pin(contentID)
        case .question: return .question(contentID)
        default: return nil
        }
    }
}

/// 本机阅读历史，对应 Android 版的本地历史。只存在本机，不上报知乎；
/// 同一内容再次阅读时移到最前，最多保留 1000 条。
@MainActor
@Observable
final class ReadingHistory {
    static let shared = ReadingHistory()

    private(set) var entries: [HistoryEntry] = []
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let limit = 1000

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("reading-history.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func record(_ detail: ContentDetail) {
        let text = HTML.plainText(detail.html)
        record(HistoryEntry(
            kind: detail.kind.rawValue,
            contentID: detail.id,
            title: detail.title,
            excerpt: String(text.prefix(100)),
            authorName: detail.author?.name,
            avatarURL: detail.author?.avatarURL,
            readAt: Date()
        ))
    }

    func record(_ pin: PinDetail) {
        let text = HTML.plainText(pin.html)
        record(HistoryEntry(
            kind: ContentKind.pin.rawValue,
            contentID: pin.id,
            title: "想法",
            excerpt: String(text.prefix(100)),
            authorName: pin.author?.name,
            avatarURL: pin.author?.avatarURL,
            readAt: Date()
        ))
    }

    private func record(_ entry: HistoryEntry) {
        guard !entry.contentID.isEmpty else { return }
        // 连续阅读时同一条反复触发，1 分钟内只刷新一次时间，避免频繁写盘。
        if let first = entries.first, first.id == entry.id, Date().timeIntervalSince(first.readAt) < 60 { return }
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        let snapshot = entries
        let url = fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

/// 知乎账号的在线浏览历史（官方 App / 网页的阅读记录），接口与字段同 Android 版 `OnlineHistoryViewModel`。
struct OnlineHistoryEntry: Hashable, Identifiable {
    var contentToken: String
    var contentType: String
    var title: String
    var summary: String
    var authorName: String?
    var detail: String
    var url: URL?
    var readTime: Int

    var id: String { "\(contentType):\(contentToken)" }

    init?(json: JSONValue) {
        let data = json["data"]
        guard let token = data["extra"]["content_token"].nonEmptyString else { return nil }
        contentToken = token
        contentType = data["extra"]["content_type"].stringValue
        title = HTML.plainText(data["header"]["title"].stringValue)
        summary = HTML.plainText(data["content"]["summary"].stringValue)
        authorName = data["content"]["author_name"].nonEmptyString
        detail = data["matrix"][0]["data"]["text"].nonEmptyString ?? contentType
        url = data["action"]["url"].nonEmptyString.flatMap(URL.init(string:))
        readTime = data["extra"]["read_time"].intValue
    }

    static let listURL = "https://api.zhihu.com/unify-consumption/read_history?offset=0&limit=20"

    func delete() async throws {
        _ = try await ZhihuClient.shared.json(
            .post,
            "https://api.zhihu.com/read_history/batch_del",
            json: ["pairs": [["content_token": contentToken, "content_type": contentType]], "clear": false]
        )
    }
}
