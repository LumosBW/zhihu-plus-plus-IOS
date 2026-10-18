import Foundation
import Observation

/// 知乎分页列表加载器，对应 Android 版 `PaginationViewModel`：
/// 第一页使用 `initialURL`，之后沿用响应中的 `paging.next`，直到 `paging.is_end`。
@MainActor
@Observable
final class PagedLoader<Item: Identifiable & Hashable> {
    private(set) var items: [Item] = []
    private(set) var isLoading = false
    private(set) var isEnd = false
    private(set) var hasLoaded = false
    var error: ZhihuError?

    @ObservationIgnored var initialURL: @MainActor () -> String
    @ObservationIgnored private let include: String?
    /// 返回非 nil 时以官方 App 身份请求：附带这些请求头，不加网页签名和 include，
    /// 与 Android 版 `mobileHomeFeedHttpClient` 一致。
    @ObservationIgnored private let appHeaders: @MainActor () -> [String: String]?
    @ObservationIgnored private let parse: @MainActor (JSONValue) -> [Item]
    /// 每次请求前以当前列表调用，首页用它向知乎上报已曝光的内容。
    @ObservationIgnored private let willLoad: @MainActor ([Item]) async -> Void
    @ObservationIgnored private var nextURL: String?
    @ObservationIgnored private var seen = Set<Item.ID>()
    @ObservationIgnored private var generation = 0

    init(
        include: String? = nil,
        appHeaders: @escaping @MainActor () -> [String: String]? = { nil },
        initialURL: @escaping @MainActor () -> String,
        parse: @escaping @MainActor (JSONValue) -> [Item],
        willLoad: @escaping @MainActor ([Item]) async -> Void = { _ in }
    ) {
        self.include = include
        self.appHeaders = appHeaders
        self.initialURL = initialURL
        self.parse = parse
        self.willLoad = willLoad
    }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load(reset: true)
    }

    func refresh() async {
        await load(reset: true)
    }

    func loadMore() async {
        guard !isLoading, !isEnd, hasLoaded else { return }
        await load(reset: false)
    }

    /// 列表滚动到接近底部时触发加载。
    func onAppear(_ item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), index >= items.count - 5 else { return }
        Task { await loadMore() }
    }

    func update(_ item: Item) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        }
    }

    func insert(_ item: Item, at index: Int = 0) {
        guard !seen.contains(item.id) else { return }
        seen.insert(item.id)
        items.insert(item, at: min(index, items.count))
    }

    func remove(where predicate: (Item) -> Bool) {
        items.removeAll(where: predicate)
    }

    /// 用预先取到的第一页数据直接填充列表（如评论预取），不再发请求。
    func seed(with json: JSONValue) {
        generation += 1
        items = []
        seen = []
        apply(json, reset: true)
    }

    private func apply(_ json: JSONValue, reset: Bool) {
        let newItems = parse(json)
        if reset {
            items = []
            seen = []
        }
        for item in newItems where !seen.contains(item.id) {
            seen.insert(item.id)
            items.append(item)
        }
        let paging = json["paging"]
        nextURL = paging["next"].nonEmptyString
        isEnd = paging["is_end"].bool ?? (nextURL == nil)
        // 部分接口在没有更多内容时仍返回 next，这里以空页兜底，避免无限请求。
        if json["data"].array.isEmpty && !reset {
            isEnd = true
        }
        hasLoaded = true
    }

    private func load(reset: Bool) async {
        if reset {
            generation += 1
        } else if isLoading {
            return
        }
        let currentGeneration = generation
        isLoading = true
        error = nil
        await willLoad(items)
        let url = reset ? initialURL() : (nextURL ?? initialURL())
        do {
            let headers = appHeaders()
            let json = try await ZhihuClient.shared.json(
                .get,
                url,
                include: headers == nil ? include : nil,
                headers: headers ?? [:],
                sign: headers == nil
            )
            guard currentGeneration == generation else { return }
            apply(json, reset: reset)
        } catch let zhihuError as ZhihuError {
            guard currentGeneration == generation else { return }
            error = zhihuError
            hasLoaded = true
        } catch {
            guard currentGeneration == generation else { return }
            self.error = ZhihuError(message: error.localizedDescription)
            hasLoaded = true
        }
        isLoading = false
    }
}
