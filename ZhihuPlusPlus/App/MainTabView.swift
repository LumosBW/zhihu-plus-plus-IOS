import SwiftUI

enum MainTab: String, CaseIterable, Hashable {
    case home
    case hot
    case daily
    case account

    var title: String {
        switch self {
        case .home: return "首页"
        case .hot: return "热榜"
        case .daily: return "日报"
        case .account: return "我的"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .hot: return "flame"
        case .daily: return "newspaper"
        case .account: return "person.crop.circle"
        }
    }
}

/// 主界面的横向页面。首页的「推荐」「发现」是两页，都归属底部的“首页” Tab，
/// 所以在推荐上左滑先到发现，再左滑才到热榜，和知乎官方的嵌套滑动一致。
enum MainPage: Hashable, CaseIterable {
    case recommend
    case discover
    case hot
    case daily
    case account

    var tab: MainTab {
        switch self {
        case .recommend, .discover: return .home
        case .hot: return .hot
        case .daily: return .daily
        case .account: return .account
        }
    }

    var source: RecommendationSource? {
        switch self {
        case .recommend: return .web
        case .discover: return .android
        default: return nil
        }
    }

    static func page(for source: RecommendationSource) -> MainPage {
        source == .web ? .recommend : .discover
    }
}

/// 首页顶栏高度（不含状态栏），首页两页的列表据此留出顶部空间。
let homeHeaderHeight: CGFloat = 92

/// 主界面：各页横向排成可跟手翻页的容器，底部是自绘的悬浮 Tab 栏。
///
/// 系统 TabView 不支持左右滑动切换，所以改用分页 ScrollView 承载各页的导航栈。
/// 进入详情页后禁用翻页并隐藏 Tab 栏，横向手势留给全屏右滑返回（见 `FullScreenSwipeBack`）。
struct MainTabView: View {
    @AppStorage("selectedTab") private var selection: MainTab = .home
    @Environment(AppSettings.self) private var settings
    @State private var routers = Dictionary(uniqueKeysWithValues: MainPage.allCases.map { ($0, Router()) })
    @State private var scrolledPage: MainPage?
    /// 翻页进度（0 = 推荐页），驱动首页标签下划线和 Tab 栏高亮跟手移动。
    @State private var pageProgress: CGFloat = 0
    /// Tab 栏是否收起（进入详情页时）。单独用状态驱动并显式加动画：
    /// 右滑返回时导航路径是在关闭了动画的事务里更新的，直接跟随路径会让 Tab 栏闪现。
    @State private var barHidden = false

    private var currentPage: MainPage { scrolledPage ?? initialPage }
    private var initialPage: MainPage {
        selection == .home ? MainPage.page(for: settings.recommendationSource) : MainPage.allCases.first { $0.tab == selection }!
    }
    private var isAtRoot: Bool { routers[currentPage]!.path.isEmpty }
    private var homeAtRoot: Bool { routers[.recommend]!.path.isEmpty && routers[.discover]!.path.isEmpty }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(MainPage.allCases, id: \.self) { page in
                        TabRoot(page: page, router: routers[page]!)
                            .containerRelativeFrame(.horizontal)
                            .id(page)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrolledPage)
            .scrollIndicators(.hidden)
            .scrollDisabled(!isAtRoot)
            // 键盘让位由各页自己处理（见 `KeyboardAvoidance`），翻页容器和悬浮 Tab 栏保持不动。
            .ignoresSafeArea(.keyboard)
            .modifier(PageProgressTracker(progress: $pageProgress))
            .overlay(alignment: .top) {
                // 首页顶栏固定在推荐 / 发现两页上方；滑向热榜时随页面一起移出屏幕。
                if homeAtRoot {
                    HomeHeader(
                        progress: min(max(pageProgress, 0), 1),
                        onSelect: { source in
                            withAnimation(.snappy) { scrolledPage = MainPage.page(for: source) }
                        },
                        onOpen: { route in
                            routers[currentPage.tab == .home ? currentPage : .recommend]!.open(route)
                        }
                    )
                    .offset(x: -max(0, pageProgress - 1) * proxy.size.width)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                // 推荐、发现两页都对应“首页” Tab，高亮在这两页之间保持不动。
                FloatingTabBar(selection: selection, progress: max(0, pageProgress - 1)) { tab in
                    if tab == selection {
                        // 在详情页时先回到根页面，已在根页面时滚回顶部。
                        let router = routers[currentPage]!
                        if router.path.isEmpty {
                            router.scrollToTop()
                        } else {
                            router.popToRoot()
                        }
                    } else {
                        let target = tab == .home ? MainPage.page(for: settings.recommendationSource) : MainPage.allCases.first { $0.tab == tab }!
                        withAnimation(.snappy) { scrolledPage = target }
                    }
                }
                .offset(y: barHidden ? 120 : 0)
                .opacity(barHidden ? 0 : 1)
                .allowsHitTesting(!barHidden)
            }
        }
        .onChange(of: isAtRoot) { _, atRoot in
            // 推迟到下一轮主循环，脱离导航更新所在的“禁用动画”事务，动画才会生效。
            DispatchQueue.main.async {
                withAnimation(atRoot ? .spring(duration: 0.4, bounce: 0.15) : .easeIn(duration: 0.2)) {
                    barHidden = !atRoot
                }
            }
        }
        .onAppear {
            let page = initialPage
            scrolledPage = page
            pageProgress = CGFloat(MainPage.allCases.firstIndex(of: page) ?? 0)
        }
        .onChange(of: scrolledPage) { _, page in
            guard let page else { return }
            selection = page.tab
            // 记住上次停留的首页标签，下次打开 App 或点“首页” Tab 时回到这里。
            if let source = page.source { settings.recommendationSource = source }
        }
    }
}

/// 读取横向翻页进度。`onScrollGeometryChange` 需要 iOS 18；iOS 17 上高亮在翻页结束后再移动。
private struct PageProgressTracker: ViewModifier {
    @Binding var progress: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.width > 0 ? geometry.contentOffset.x / geometry.containerSize.width : 0
            } action: { _, newValue in
                progress = newValue
            }
        } else {
            content
        }
    }
}

private struct FloatingTabBar: View {
    let selection: MainTab
    let progress: CGFloat
    let onSelect: (MainTab) -> Void

    var body: some View {
        let tabs = MainTab.allCases
        let position: CGFloat = {
            if #available(iOS 18.0, *) { return min(max(progress, 0), CGFloat(tabs.count - 1)) }
            return CGFloat(tabs.firstIndex(of: selection) ?? 0)
        }()
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                let distance = abs(CGFloat(tabs.firstIndex(of: tab)!) - position)
                Button {
                    onSelect(tab)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon).font(.system(size: 20, weight: .medium))
                        Text(tab.title).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(distance < 0.5 ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(alignment: .leading) {
            GeometryReader { proxy in
                let width = proxy.size.width / CGFloat(tabs.count)
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: width, height: proxy.size.height)
                    .offset(x: width * position)
            }
        }
        .padding(4)
        .modifier(TabBarBackground())
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
    }
}

private struct TabBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}

/// 每页拥有独立的导航栈与路由。
private struct TabRoot: View {
    let page: MainPage
    let router: Router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            rootView
                // 给悬浮 Tab 栏让出位置；只加在根页面，详情页 Tab 栏隐藏后不占空间。
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 64) }
                .background(FullScreenSwipeBack())
                .navigationDestination(for: Route.self) { route in
                    // 加在每个详情页上：加在 NavigationStack 外面时，推入的页面收不到这段安全区。
                    RouteView(route: route).keyboardAvoidance()
                }
        }
        .environment(router)
        .sheet(item: Binding(
            get: { router.safariURL.map(IdentifiableURL.init) },
            set: { router.safariURL = $0?.url }
        )) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
        .sheet(item: Binding(
            get: { router.verificationURL.map(IdentifiableURL.init) },
            set: { router.verificationURL = $0?.url }
        )) { item in
            VerificationView(url: item.url)
        }
    }

    @ViewBuilder
    private var rootView: some View {
        switch page {
        case .recommend: HomeFeedView(source: .web)
        case .discover: HomeFeedView(source: .android)
        case .hot: HotListView()
        case .daily: DailyView()
        case .account: AccountView()
        }
    }
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .answer(let id):
            ContentDetailView(kind: .answer, id: id)
        case .article(let id):
            ContentDetailView(kind: .article, id: id)
        case .question(let id):
            QuestionView(id: id)
        case .pin(let id):
            PinView(id: id)
        case .people(let token):
            PeopleView(token: token)
        case .comments(let kind, let id):
            CommentsView(kind: kind, id: id)
        case .childComments(let id):
            ChildCommentsView(commentID: id)
        case .collections(let token):
            CollectionsView(token: token)
        case .collection(let id, let title):
            CollectionItemsView(id: id, title: title)
        case .dailyStory(let id, let title):
            DailyStoryView(id: id, title: title)
        case .search:
            SearchView()
        case .settings:
            SettingsView()
        case .history:
            HistoryView()
        case .blocklist:
            BlocklistView()
        case .web(let url):
            SafariView(url: url).ignoresSafeArea().toolbar(.hidden, for: .navigationBar)
        }
    }
}
