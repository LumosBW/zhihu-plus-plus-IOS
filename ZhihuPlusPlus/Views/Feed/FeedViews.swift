import SwiftUI

/// 通用的信息流列表：下拉刷新、触底加载、点击进入详情、长按屏蔽。
struct FeedListView: View {
    let loader: PagedLoader<FeedItem>
    var emptyText = "暂无内容"
    /// 点开条目时额外执行，首页用它上报已读。
    var onOpen: (FeedItem) -> Void = { _ in }
    @Environment(Router.self) private var router

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(loader.items) { item in
                    Button {
                        guard let route = item.target.route else { return }
                        onOpen(item)
                        router.open(route)
                    } label: {
                        FeedRowView(item: item)
                            .feedCard()
                    }
                    .buttonStyle(.plain)
                    .plainCardRow()
                    .contextMenu { FeedItemMenu(item: item, loader: loader) }
                    .onAppear { loader.onAppear(item) }
                }
                LoadMoreFooter(loader: loader, emptyText: emptyText)
            }
            .cardListStyle()
            .refreshable { await loader.refresh() }
            .task { await loader.loadIfNeeded() }
            .scrollsToTop(on: router.scrollToTopRequest, first: loader.items.first?.id, proxy: proxy)
        }
    }
}

struct FeedItemMenu: View {
    let item: FeedItem
    let loader: PagedLoader<FeedItem>
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let url = item.target.shareURL {
            ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
            Button {
                UIPasteboard.general.url = url
            } label: {
                Label("复制链接", systemImage: "link")
            }
        }
        if let author = item.target.author, !author.id.isEmpty, author.id != "0" {
            Button(role: .destructive) {
                settings.blockUser(id: author.id, name: author.name)
                loader.remove { $0.target.author?.id == author.id }
            } label: {
                Label("屏蔽用户 \(author.name)", systemImage: "person.slash")
            }
        }
        Button(role: .destructive) {
            loader.remove { $0.id == item.id }
        } label: {
            Label("不感兴趣", systemImage: "hand.thumbsdown")
        }
    }
}

// MARK: - 首页

/// 首页的一页：「推荐」用网页版推荐算法，「发现」以官方安卓 App 身份请求同一地址。
/// 顶栏由 `MainTabView` 统一叠在两页上方，这里只留出它的高度。
struct HomeFeedView: View {
    @State private var loader: PagedLoader<FeedItem>

    init(source: RecommendationSource) {
        _loader = State(initialValue: PagedLoader<FeedItem>(
            include: ZhihuAPI.feedInclude,
            appHeaders: { source.appHeaders },
            initialURL: { RecommendationSource.url },
            parse: { json in
                // 发现页（安卓端）卡片不带作者粉丝数、是否关注等字段，质量过滤会误杀，与 Android 版一致只在推荐页启用。
                ContentFilter.apply(
                    FeedParser.items(from: json["data"].array),
                    options: .init(quality: source == .web)
                )
            },
            // 与 Android 版一致，每次请求前把已展示的内容报为已曝光，推荐接口才不会重复推送。
            willLoad: { await LastReadReporter.shared.touch($0) }
        ))
    }

    var body: some View {
        FeedListView(loader: loader, onOpen: { LastReadReporter.shared.read($0) })
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: homeHeaderHeight)
            }
    }
}

/// 首页顶栏：品牌字标 + 轮播热搜的搜索框 + 设置入口，下面是「推荐 / 发现」两个标签。
/// `progress` 为 0 时在推荐、1 时在发现，下划线随翻页进度跟手移动。
struct HomeHeader: View {
    let progress: CGFloat
    let onSelect: (RecommendationSource) -> Void
    /// 顶栏在导航栈之外，搜索 / 设置交给当前首页的路由打开。
    let onOpen: (Route) -> Void
    @State private var hotQueries: [String] = []
    @State private var hotIndex = 0

    private let tabWidth: CGFloat = 40
    private let tabSpacing: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("知乎++")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.brand)

                Button {
                    onOpen(.search)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text(hotQueries.isEmpty ? "搜索知乎内容" : hotQueries[hotIndex % hotQueries.count])
                            .lineLimit(1)
                            .id(hotIndex)
                            .transition(.push(from: .bottom))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Theme.card, in: Capsule())
                    .clipped()
                }
                .buttonStyle(.plain)

                Button {
                    onOpen(.settings)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
            }

            HStack(spacing: tabSpacing) {
                ForEach(Array(RecommendationSource.allCases.enumerated()), id: \.element) { index, source in
                    let weight = 1 - min(abs(progress - CGFloat(index)), 1)
                    Button {
                        onSelect(source)
                    } label: {
                        Text(source.label)
                            .font(.system(size: 16, weight: weight > 0.5 ? .semibold : .regular))
                            .foregroundStyle(Color.primary.opacity(0.5 + 0.5 * weight))
                            .frame(width: tabWidth, height: 26)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Capsule().fill(Theme.brand)
                    .frame(width: 16, height: 3)
                    .offset(x: (tabWidth - 16) / 2 + progress * (tabWidth + tabSpacing), y: 3)
            }
        }
        .padding(.horizontal, Theme.pagePadding + 4)
        .padding(.top, 6)
        .frame(height: homeHeaderHeight, alignment: .top)
        .background(Theme.background.ignoresSafeArea(edges: .top))
        .task {
            if hotQueries.isEmpty {
                hotQueries = (try? await ZhihuAPI.hotSearch()) ?? []
            }
            // 每 4 秒轮换一个热搜词。
            while !Task.isCancelled, hotQueries.count > 1 {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeInOut(duration: 0.35)) { hotIndex += 1 }
            }
        }
    }
}

// MARK: - 热榜

struct HotListView: View {
    @Environment(Router.self) private var router
    @State private var loader = PagedLoader<FeedItem>(
        initialURL: { ZhihuAPI.hotListURL },
        parse: { json in
            ContentFilter.apply(
                FeedParser.items(from: json["data"].array),
                options: .init(quality: false, paid: false)
            )
        }
    )

    /// 热度文本（“1101 万热度”）换算成数值，用于画热度条。
    private static func heat(_ text: String?) -> Double {
        guard let text else { return 0 }
        let digits = text.prefix { $0.isNumber || $0 == "." }
        let value = Double(digits) ?? 0
        if text.contains("亿") { return value * 10_000 }
        return text.contains("万") ? value : value / 10_000
    }

    var body: some View {
        let maxHeat = max(loader.items.map { Self.heat($0.metricText) }.max() ?? 1, 1)
        ScrollViewReader { proxy in
            List {
                ForEach(Array(loader.items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        if let route = item.target.route { router.open(route) }
                    } label: {
                        HotRow(rank: index + 1, item: item, heatRatio: Self.heat(item.metricText) / maxHeat)
                            .feedCard()
                    }
                    .buttonStyle(.plain)
                    .plainCardRow()
                }
                LoadMoreFooter(loader: loader)
            }
            .cardListStyle()
            .refreshable { await loader.refresh() }
            .task { await loader.loadIfNeeded() }
            .scrollsToTop(on: router.scrollToTopRequest, first: loader.items.first?.id, proxy: proxy)
        }
        .navigationTitle("热榜")
    }
}

private struct HotRow: View {
    let rank: Int
    let item: FeedItem
    let heatRatio: Double
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var rankWidth = 24.0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 2) {
                Text("\(rank)")
                    .font((rank <= 3 ? Font.title2 : Font.headline).weight(.heavy).italic())
                    .foregroundStyle(rank <= 3 ? AnyShapeStyle(Theme.rankGradient(rank)) : AnyShapeStyle(Theme.metaText))
                if rank <= 3 {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.rankGradient(rank))
                }
            }
            .frame(width: rankWidth)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Text(item.target.title)
                        .font(Theme.Font.cardTitle)
                        .foregroundStyle(.primary)
                        .lineSpacing(2)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let thumbnail = item.target.thumbnail, !dynamicTypeSize.isAccessibilitySize {
                        ThumbnailView(url: thumbnail, width: 72, height: 56)
                    }
                }
                if !item.target.excerpt.isEmpty, !dynamicTypeSize.isAccessibilitySize {
                    Text(item.target.excerpt)
                        .font(Theme.Font.excerpt)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                if let metric = item.metricText {
                    HStack(spacing: 8) {
                        if !dynamicTypeSize.isAccessibilitySize {
                            GeometryReader { proxy in
                                Capsule().fill(Color.secondary.opacity(0.12))
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(rank <= 3 ? AnyShapeStyle(Theme.rankGradient(rank)) : AnyShapeStyle(Theme.brand.opacity(0.6)))
                                            .frame(width: max(6, proxy.size.width * heatRatio))
                                    }
                            }
                            .frame(width: 48, height: 4)
                            .accessibilityHidden(true)
                        }
                        Text(metric)
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.metaText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 日报

@MainActor
@Observable
final class DailyModel {
    struct Section: Identifiable {
        var date: String
        var stories: [DailyStory]
        var id: String { date }
    }

    var sections: [Section] = []
    var topStories: [DailyStory] = []
    var isLoading = false
    var error: ZhihuError?

    func load(reset: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let before = reset ? nil : sections.last?.date
            let result = try await ZhihuAPI.dailyStories(before: before)
            let section = Section(date: result.date, stories: result.stories)
            if reset {
                sections = [section]
                topStories = result.topStories
            } else if !sections.contains(where: { $0.date == section.date }) {
                sections.append(section)
            }
        } catch {
            self.error = error.asZhihuError
        }
    }

    static func displayDate(_ raw: String) -> String {
        guard raw.count == 8 else { return raw }
        let year = raw.prefix(4)
        let month = raw.dropFirst(4).prefix(2)
        let day = raw.suffix(2)
        return "\(year) 年 \(month) 月 \(day) 日"
    }
}

struct DailyView: View {
    @Environment(Router.self) private var router
    @State private var model = DailyModel()

    var body: some View {
        List {
            if !model.topStories.isEmpty {
                TabView {
                    ForEach(model.topStories) { story in
                        Button {
                            router.open(.dailyStory(story.id, story.title))
                        } label: {
                            DailyBanner(story: story)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .plainCardRow()
            }
            ForEach(model.sections) { section in
                Text(DailyModel.displayDate(section.date))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .plainCardRow()
                ForEach(section.stories) { story in
                    Button {
                        router.open(.dailyStory(story.id, story.title))
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(story.title)
                                    .font(Theme.Font.cardTitle)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(story.hint).font(Theme.Font.meta).foregroundStyle(Theme.metaText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            ThumbnailView(url: story.image, width: 76, height: 76)
                        }
                        .feedCard()
                    }
                    .buttonStyle(.plain)
                    .plainCardRow()
                }
            }
            Group {
                if let error = model.error {
                    ErrorStateView(error: error) { Task { await model.load(reset: model.sections.isEmpty) } }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .onAppear { Task { await model.load(reset: model.sections.isEmpty) } }
                }
            }
            .plainCardRow()
        }
        .cardListStyle()
        .refreshable { await model.load(reset: true) }
        .navigationTitle("知乎日报")
    }
}

/// 日报头条横幅：大图铺满，底部渐变上叠标题。
private struct DailyBanner: View {
    let story: DailyStory

    var body: some View {
        // 图片放在固定尺寸容器的 overlay 里，scaledToFill 溢出的部分不会撑大容器，标题才能贴着可见区域底部。
        Color.clear
            .overlay {
                AsyncImage(url: story.image) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(story.title)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(2)
                if !story.hint.isEmpty {
                    Text(story.hint).font(Theme.Font.meta).opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
        }
        .contentShape(Rectangle())
    }
}

/// 日报文章：优先跳转到原始知乎回答 / 文章，找不到时直接渲染日报正文。
struct DailyStoryView: View {
    let id: String
    let title: String
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router
    @State private var state: LoadState<(route: Route?, body: String, css: [String])> = .loading
    @State private var imageURL: URL?

    var body: some View {
        StatefulView(state: state, retry: { Task { await load() } }) { value in
            if let route = value.route {
                RouteView(route: route)
            } else {
                HTMLContentView(
                    html: "<h1>\(HTML.escape(title))</h1>" + value.body,
                    fontSize: settings.fontSize,
                    extraCSS: ".img-place-holder { display: none; } .headline .img-wrap { display: none; } .meta .avatar { width: 20px; height: 20px; display: inline; border-radius: 50%; }",
                    onLink: { router.open(url: $0) },
                    onImage: { imageURL = $0 }
                )
                .navigationTitle("日报")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .imageViewer($imageURL)
        .task {
            if case .loading = state { await load() }
        }
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await ZhihuAPI.dailyStoryOrigin(id))
        } catch {
            state = .failed(error.asZhihuError)
        }
    }
}

// MARK: - 搜索

struct SearchView: View {
    @Environment(Router.self) private var router
    @State private var text = ""
    @State private var submitted = ""
    @State private var hotQueries: [String] = []
    @AppStorage("searchHistory") private var historyRaw = ""
    @State private var loader = PagedLoader<SearchResult>(
        include: "data[*].highlight,object,type",
        initialURL: { "" },
        parse: { json in SearchResult.parse(json["data"].array) }
    )

    private var history: [String] {
        historyRaw.split(separator: "\n").map(String.init)
    }

    var body: some View {
        List {
            if submitted.isEmpty {
                if !history.isEmpty {
                    Section {
                        ForEach(history, id: \.self) { query in
                            Button(query) { search(query) }
                        }
                    } header: {
                        HStack {
                            Text("搜索历史")
                            Spacer()
                            Button("清除") { historyRaw = "" }.font(.caption)
                        }
                    }
                }
                if !hotQueries.isEmpty {
                    Section("知乎热搜") {
                        ForEach(Array(hotQueries.enumerated()), id: \.offset) { index, query in
                            Button {
                                search(query)
                            } label: {
                                HStack {
                                    Text("\(index + 1)").foregroundStyle(index < 3 ? .orange : .secondary).frame(width: 24)
                                    Text(query).foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
            } else {
                ForEach(loader.items) { result in
                    resultRow(result)
                        .onAppear { loader.onAppear(result) }
                }
                LoadMoreFooter(loader: loader, emptyText: "没有找到相关内容")
            }
        }
        .listStyle(.plain)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索知乎内容")
        .onSubmit(of: .search) { search(text) }
        .onChange(of: text) { _, newValue in
            if newValue.isEmpty { submitted = "" }
        }
        .task {
            if hotQueries.isEmpty {
                hotQueries = (try? await ZhihuAPI.hotSearch()) ?? []
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ result: SearchResult) -> some View {
        switch result {
        case .content(let item):
            Button {
                if let route = item.target.route { router.open(route) }
            } label: {
                FeedRowView(item: item)
            }
            .buttonStyle(.plain)
        case .people(let author):
            Button {
                if let key = author.profileKey { router.open(.people(key)) }
            } label: {
                HStack(spacing: 12) {
                    AvatarView(url: author.avatarURL, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(author.name).font(.headline)
                        Text(author.headline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = trimmed
        submitted = trimmed
        historyRaw = ([trimmed] + history.filter { $0 != trimmed }).prefix(20).joined(separator: "\n")
        loader.initialURL = { ZhihuAPI.searchURL(trimmed) }
        Task { await loader.refresh() }
    }
}
