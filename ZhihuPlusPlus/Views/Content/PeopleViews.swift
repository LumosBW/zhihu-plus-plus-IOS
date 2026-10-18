import SwiftUI

struct PeopleView: View {
    let token: String
    @Environment(Router.self) private var router
    @Environment(AccountStore.self) private var account
    @Environment(AppSettings.self) private var settings
    @State private var profile: PeopleProfile?
    @State private var profileError: ZhihuError?
    @State private var tab: ContentKind = .answer
    @State private var answers: PagedLoader<FeedItem>
    @State private var articles: PagedLoader<FeedItem>

    init(token: String) {
        self.token = token
        let include = "data[*].excerpt,voteup_count,comment_count,created_time,updated_time,question,author"
        _answers = State(initialValue: PagedLoader(
            include: include,
            initialURL: { ZhihuAPI.memberContentURL(token, kind: .answer) },
            parse: { json in FeedParser.items(from: json["data"].array) }
        ))
        _articles = State(initialValue: PagedLoader(
            include: include,
            initialURL: { ZhihuAPI.memberContentURL(token, kind: .article) },
            parse: { json in FeedParser.items(from: json["data"].array) }
        ))
    }

    private var loader: PagedLoader<FeedItem> { tab == .article ? articles : answers }

    var body: some View {
        List {
            Section { header }
            Section {
                Picker("内容", selection: $tab) {
                    Text("回答").tag(ContentKind.answer)
                    Text("文章").tag(ContentKind.article)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                ForEach(loader.items) { item in
                    Button {
                        if let route = item.target.route { router.open(route) }
                    } label: {
                        FeedRowView(item: item)
                    }
                    .buttonStyle(.plain)
                    .onAppear { loader.onAppear(item) }
                }
                LoadMoreFooter(loader: loader, emptyText: "还没有内容")
            }
        }
        .listStyle(.plain)
        .navigationTitle(profile?.name ?? "用户")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadProfile()
            await loader.refresh()
        }
        .task {
            if profile == nil { await loadProfile() }
            await loader.loadIfNeeded()
        }
        .onChange(of: tab) { _, _ in
            Task { await loader.loadIfNeeded() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let url = URL(string: "https://www.zhihu.com/people/\(token)") {
                        ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                    }
                    if let profile {
                        Button {
                            router.open(.collections(profile.urlToken.isEmpty ? token : profile.urlToken))
                        } label: {
                            Label("TA 的收藏夹", systemImage: "star")
                        }
                        Button(role: .destructive) {
                            settings.blockUser(id: profile.id, name: profile.name)
                        } label: {
                            Label("在 Zhihu++ 中屏蔽", systemImage: "person.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if let profile {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    AvatarView(url: profile.avatarURL, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name).font(.title3.weight(.bold))
                        if !profile.headline.isEmpty {
                            Text(profile.headline).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let ip = profile.ipInfo {
                            Text(ip).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                if !profile.description.isEmpty {
                    Text(profile.description).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                }
                HStack(spacing: 0) {
                    stat("关注者", profile.followerCount)
                    stat("关注了", profile.followingCount)
                    stat("回答", profile.answerCount)
                    stat("文章", profile.articleCount)
                }
                if account.isLoggedIn, profile.id != account.profile?.id {
                    Button(profile.isFollowing ? "已关注" : "关注") {
                        Task { await toggleFollow() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(profile.isFollowing ? .gray : .accentColor)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
        } else if let profileError {
            ErrorStateView(error: profileError) { Task { await loadProfile() } }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text(Format.count(value)).font(.headline)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func loadProfile() async {
        do {
            profile = try await ZhihuAPI.people(token)
            profileError = nil
        } catch {
            profileError = error.asZhihuError
        }
    }

    private func toggleFollow() async {
        guard var profile else { return }
        do {
            try await ZhihuAPI.followMember(profile.urlToken.isEmpty ? token : profile.urlToken, follow: !profile.isFollowing)
            profile.isFollowing.toggle()
            profile.followerCount += profile.isFollowing ? 1 : -1
            self.profile = profile
        } catch {
            profileError = error.asZhihuError
        }
    }
}

// MARK: - 收藏夹

struct CollectionsView: View {
    let token: String
    @Environment(Router.self) private var router
    @State private var loader: PagedLoader<CollectionInfo>

    init(token: String) {
        self.token = token
        _loader = State(initialValue: PagedLoader(
            initialURL: { "https://www.zhihu.com/api/v4/people/\(token)/collections?limit=20" },
            parse: { json in json["data"].array.compactMap(CollectionInfo.init(json:)) }
        ))
    }

    var body: some View {
        List {
            ForEach(loader.items) { collection in
                Button {
                    router.open(.collection(collection.id, collection.title))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(collection.title).font(.headline)
                            if !collection.isPublic {
                                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !collection.description.isEmpty {
                            Text(collection.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text("\(collection.itemCount) 条内容 · \(collection.followerCount) 关注")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .onAppear { loader.onAppear(collection) }
            }
            LoadMoreFooter(loader: loader, emptyText: "没有收藏夹")
        }
        .listStyle(.plain)
        .navigationTitle("收藏夹")
        .refreshable { await loader.refresh() }
        .task { await loader.loadIfNeeded() }
    }
}

struct CollectionItemsView: View {
    let id: String
    let title: String
    @State private var loader: PagedLoader<FeedItem>

    init(id: String, title: String) {
        self.id = id
        self.title = title
        _loader = State(initialValue: PagedLoader(
            initialURL: { "https://www.zhihu.com/api/v4/collections/\(id)/items?offset=0&limit=20" },
            parse: { json in FeedParser.items(from: json["data"].array) }
        ))
    }

    var body: some View {
        FeedListView(loader: loader, emptyText: "收藏夹是空的")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
