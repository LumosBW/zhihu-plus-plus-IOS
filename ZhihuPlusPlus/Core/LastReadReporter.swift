import Foundation

/// 向知乎上报首页推荐内容的曝光（touch）与阅读（read），对应 Android 版 `HomeFeedViewModel.markItemsAsTouched` / `onUiContentClick`。
/// 推荐接口依赖这份记录排除看过的内容，不上报就会反复推同样的回答。
@MainActor
final class LastReadReporter {
    static let shared = LastReadReporter()

    private static let url = "https://www.zhihu.com/lastread/touch"

    /// 已成功上报 touch 的条目。推荐与发现两页共用，同一条内容只报一次。
    private var touched = Set<String>()

    /// 把列表里还没上报过的回答、文章、想法标记为已曝光。失败时下次加载再重试，不影响列表本身。
    func touch(_ items: [FeedItem]) async {
        var pending: [(key: String, entry: [String])] = []
        for item in items where !touched.contains(item.id) {
            guard let entry = Self.entry(for: item.target, action: "touch") else { continue }
            pending.append((item.id, entry))
        }
        guard !pending.isEmpty, await post(pending.map(\.entry)) else { return }
        touched.formUnion(pending.map(\.key))
    }

    /// 点开内容时标记为已读。
    func read(_ item: FeedItem) {
        guard let entry = Self.entry(for: item.target, action: "read") else { return }
        Task { await post([entry]) }
    }

    private static func entry(for target: FeedTarget, action: String) -> [String]? {
        switch target.kind {
        case .answer, .article, .pin:
            return [target.kind.rawValue, target.id, action]
        default:
            return nil
        }
    }

    @discardableResult
    private func post(_ entries: [[String]]) async -> Bool {
        let client = ZhihuClient.shared
        guard client.cookies["d_c0"] != nil,
              let data = try? JSONSerialization.data(withJSONObject: entries),
              let payload = String(data: data, encoding: .utf8) else { return false }
        let response = try? await client.send(.post, Self.url, multipart: ["items": payload]).1
        return response.map { (200..<300).contains($0.statusCode) } ?? false
    }
}
