import SwiftUI

/// 正文页公用的作者头部 HTML，点击作者跳转个人主页。
private func authorHeaderHTML(_ author: Author?) -> String {
    guard let author else { return "" }
    let avatar = author.avatarURL.map { "<img src=\"\(HTML.escape($0.absoluteString))\">" } ?? ""
    let inner = """
    \(avatar)<div><div class="name">\(HTML.escape(author.name))</div><div class="headline">\(HTML.escape(author.headline))</div></div>
    """
    if let key = author.profileKey {
        return "<a class=\"zpp-author\" href=\"\(LinkResolver.internalScheme)://people/\(ZhihuClient.percentEncode(key))\">\(inner)</a>"
    }
    return "<div class=\"zpp-author\">\(inner)</div>"
}

// MARK: - 回答 / 文章

/// 连续加载回答，每次追加一条；各条回答的操作始终绑定自己的 ID。
/// 顺序取问题回答列表（默认排序），跳过已经展示过的回答、屏蔽的作者，以及开启屏蔽时的盐选内容。
@MainActor
@Observable
final class AnswerNavigator {
    private(set) var answers: [ContentDetail] = []
    private(set) var isEnd = true
    private(set) var isLoading = false
    private(set) var error: ZhihuError?
    @ObservationIgnored private var pendingIDs: [String] = []
    @ObservationIgnored private var nextPageURL: String?
    @ObservationIgnored private var shownIDs = Set<String>()
    @ObservationIgnored private var nextTask: Task<Void, Never>?
    /// 已经取好详情、还没追加到页面的回答。保持 5 条余量（连续几条一句话回答时 3 条不够），快速滑动时直接接上，不用等网络。
    @ObservationIgnored private var buffer: [ContentDetail] = []
    @ObservationIgnored private var sourceExhausted = false
    private let bufferTarget = 5
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadedPageURLs = Set<String>()

    var current: ContentDetail? { answers.first }

    func start(with first: ContentDetail) {
        generation += 1
        nextTask?.cancel()
        nextTask = nil
        buffer = []
        isLoading = false
        error = nil
        answers = [first]
        shownIDs = [first.id]
        pendingIDs = []
        loadedPageURLs = []
        if first.kind == .answer, let questionID = first.questionID {
            nextPageURL = ZhihuAPI.questionFeedsURL(questionID, order: "default")
            sourceExhausted = false
            isEnd = false
        } else {
            nextPageURL = nil
            sourceExhausted = true
            isEnd = true
        }
        // 打开回答后立即在后台备好后面几条。
        refill()
    }

    func update(_ detail: ContentDetail) {
        if let index = answers.firstIndex(where: { $0.id == detail.id }) {
            answers[index] = detail
        }
    }

    /// 页面快滚到底时调用：缓冲里有就立即追加一条，再在后台补满缓冲；缓冲空了才等网络。
    func prepareNext(retry: Bool = false) async {
        guard !isEnd, error == nil || retry else { return }
        if retry { error = nil }
        if !buffer.isEmpty {
            appendFromBuffer()
            return
        }
        let requestGeneration = generation
        refill()
        guard let task = nextTask else { return }
        isLoading = true
        await task.value
        guard generation == requestGeneration else { return }
        isLoading = false
        if !buffer.isEmpty { appendFromBuffer() }
    }

    private func appendFromBuffer() {
        answers.append(buffer.removeFirst())
        updateEnd()
        refill()
    }

    private func updateEnd() {
        isEnd = sourceExhausted && buffer.isEmpty
    }

    private func refill() {
        guard nextTask == nil, !sourceExhausted, buffer.count < bufferTarget, error == nil else { return }
        let requestGeneration = generation
        nextTask = Task {
            await fill(generation: requestGeneration)
            guard generation == requestGeneration else { return }
            nextTask = nil
            updateEnd()
        }
    }

    private func fill(generation requestGeneration: Int) async {
        guard let first = answers.first else { return }
        let settings = AppSettings.shared
        do {
            while buffer.count < bufferTarget, !Task.isCancelled, generation == requestGeneration {
                if pendingIDs.isEmpty {
                    guard let url = nextPageURL, !loadedPageURLs.contains(url) else {
                        sourceExhausted = true
                        return
                    }
                    let json = try await ZhihuClient.shared.json(.get, url, include: ZhihuAPI.feedInclude)
                    guard !Task.isCancelled, generation == requestGeneration else { return }
                    loadedPageURLs.insert(url)
                    let ids = FeedParser.items(from: json["data"].array)
                        .filter { $0.target.kind == .answer }
                        .map(\.target.id)
                    var uniqueIDs = Set<String>()
                    pendingIDs = ids.filter { !shownIDs.contains($0) && uniqueIDs.insert($0).inserted }
                    nextPageURL = json["paging"]["is_end"].boolValue ? nil : json["paging"]["next"].nonEmptyString
                    continue
                }
                // 一批最多 5 条并发读取详情，按原顺序放进缓冲。
                let batch = Array(pendingIDs.prefix(bufferTarget))
                let details = try await withThrowingTaskGroup(of: (Int, ContentDetail).self) { group in
                    for (index, id) in batch.enumerated() {
                        group.addTask { (index, try await ZhihuAPI.contentDetail(kind: .answer, id: id)) }
                    }
                    var results: [(Int, ContentDetail)] = []
                    for try await result in group { results.append(result) }
                    return results.sorted { $0.0 < $1.0 }.map(\.1)
                }
                guard !Task.isCancelled, generation == requestGeneration else { return }
                // 读取成功后才移出队列，失败重试不会跳过这一批。
                pendingIDs.removeFirst(batch.count)
                for var detail in details {
                    shownIDs.insert(detail.id)
                    if let authorID = detail.author?.id, settings.blockedUsers.contains(where: { $0.id == authorID }) { continue }
                    if settings.blockPaidContent, detail.isPaid { continue }
                    detail.questionAnswerCount = first.questionAnswerCount
                    detail.questionFollowerCount = first.questionFollowerCount
                    buffer.append(detail)
                }
            }
        } catch {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            self.error = error.asZhihuError
        }
    }
}

struct ContentDetailView: View {
    let kind: ContentKind
    let id: String
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(AccountStore.self) private var account
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var loadState: LoadState<Void> = .loading
    @State private var navigator = AnswerNavigator()
    @State private var imageURL: URL?
    @State private var votingIDs = Set<String>()
    @State private var followingIDs = Set<String>()
    @State private var shareTarget: ContentDetail?
    @State private var menuTarget: ContentDetail?
    @State private var showsAnswerMenu = false
    @State private var actionError: String?
    @State private var favoriteTarget: ContentDetail?

    var body: some View {
        StatefulView(state: loadState, retry: { Task { await load() } }) { _ in
            if let detail = navigator.current {
                if kind == .answer {
                    HTMLContentView(
                        sections: navigator.answers.enumerated().map { index, answer in
                            answerHTML(answer, showsTitle: index == 0)
                        },
                        fontSize: settings.fontSize,
                        extraCSS: Self.answerCSS,
                        footerHTML: streamFooter,
                        onLink: { router.open(url: $0) },
                        onImage: { imageURL = $0 },
                        onNearEnd: { Task { await navigator.prepareNext() } },
                        onReaderAction: answerAction,
                        onVisibleSection: { index in
                            // 连续阅读时，滑到哪个回答就把它记进本机浏览历史。
                            if navigator.answers.indices.contains(index) {
                                ReadingHistory.shared.record(navigator.answers[index])
                            }
                        }
                    )
                    // 正文铺到屏幕底边（Home 指示条下方），不留空白；
                    // WKWebView 会自动给滚动内容加上底部安全区内边距，最后一行不会被指示条挡住。
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    HTMLContentView(
                        html: documentBody(detail, showsTitle: true),
                        fontSize: settings.fontSize,
                        onLink: { router.open(url: $0) },
                        onImage: { imageURL = $0 }
                    )
                    .safeAreaInset(edge: .bottom) { bottomBar(detail) }
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { menu(detail) } }
                }
            }
        }
        .task(id: navigator.answers.map(\.id)) {
            // 每加载出一个回答 / 文章就在后台预取评论，点进评论区可以直接显示。
            for detail in navigator.answers {
                CommentPrefetcher.prefetch(kind: detail.kind, id: detail.id)
            }
        }
        .navigationTitle(kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .imageViewer($imageURL)
        .alert("操作失败", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .sheet(item: $favoriteTarget) { target in
            FavoriteSheet(kind: target.kind, id: target.id) { favorited, delta in
                guard var current = navigator.answers.first(where: { $0.id == target.id }) else { return }
                current.isFavorited = favorited
                current.favoriteCount = max(0, current.favoriteCount + delta)
                navigator.update(current)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $shareTarget) { target in
            if let url = target.shareURL { AnswerShareSheet(url: url).presentationDetents([.medium, .large]) }
        }
        .confirmationDialog("回答操作", isPresented: $showsAnswerMenu, titleVisibility: .hidden) {
            if let target = menuTarget {
                if let url = target.shareURL {
                    Button("复制链接") { UIPasteboard.general.url = url }
                    Button("在浏览器中打开") { router.safariURL = url }
                }
                if let questionID = target.questionID {
                    Button("查看问题全部回答") { router.open(.question(questionID)) }
                }
                if let author = target.author, author.profileKey != nil {
                    Button("屏蔽作者", role: .destructive) { settings.blockUser(id: author.id, name: author.name) }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .task {
            if case .loading = loadState { await load() }
        }
    }

    private var streamFooter: String {
        if let error = navigator.error {
            let verification = error.verificationURL == nil ? "" : "<button data-reader-action=\"verify\">完成验证</button>"
            return "<div class=\"zpp-stream-status\">后续回答加载失败 <button data-reader-action=\"retry\">重试</button>\(verification)</div>"
        }
        return "<div class=\"zpp-stream-status\">\(navigator.isEnd ? "已看完全部回答" : "正在加载更多回答…")</div>"
    }

    private func answerAction(_ action: String, _ answerID: String) {
        if action == "retry" { Task { await navigator.prepareNext(retry: true) }; return }
        if action == "verify" { router.verificationURL = navigator.error?.verificationURL; return }
        guard let detail = navigator.answers.first(where: { $0.id == answerID }) else { return }
        switch action {
        case "up": Task { await setVote(detail, to: detail.voteState == .up ? .neutral : .up) }
        case "down": Task { await setVote(detail, to: detail.voteState == .down ? .neutral : .down) }
        case "comments": router.open(.comments(.answer, detail.id))
        case "favorite":
            if account.isLoggedIn { favoriteTarget = detail } else { actionError = "请先登录" }
        case "follow": Task { await toggleAuthorFollow(detail) }
        case "share": shareTarget = detail
        case "more": menuTarget = detail; showsAnswerMenu = true
        default: break
        }
    }

    private func toggleAuthorFollow(_ detail: ContentDetail) async {
        guard account.isLoggedIn else { actionError = "请先登录"; return }
        guard let author = detail.author, let key = author.profileKey, !followingIDs.contains(author.id) else { return }
        followingIDs.insert(author.id)
        defer { followingIDs.remove(author.id) }
        do {
            try await ZhihuAPI.followMember(key, follow: !author.isFollowing)
            for var answer in navigator.answers where answer.author?.id == author.id {
                answer.author?.isFollowing = !author.isFollowing
                navigator.update(answer)
            }
        } catch { actionError = error.asZhihuError.message }
    }

    private func menu(_ detail: ContentDetail) -> some View {
        Menu {
            if let url = detail.shareURL {
                ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                Button {
                    UIPasteboard.general.url = url
                } label: {
                    Label("复制链接", systemImage: "link")
                }
                Button {
                    router.safariURL = url
                } label: {
                    Label("在浏览器中打开", systemImage: "safari")
                }
            }
            if let questionID = detail.questionID {
                Button {
                    router.open(.question(questionID))
                } label: {
                    Label("查看问题全部回答", systemImage: "list.bullet")
                }
            }
            if let author = detail.author, author.id != "0" {
                Button(role: .destructive) {
                    settings.blockUser(id: author.id, name: author.name)
                } label: {
                    Label("屏蔽作者", systemImage: "person.slash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func titleHTML(_ detail: ContentDetail) -> String {
        var html = ""
        if let cover = detail.titleImage {
            html += "<img class=\"zpp-cover\" src=\"\(HTML.escape(cover.absoluteString))\">"
        }
        if !detail.title.isEmpty {
            if let questionID = detail.questionID {
                let questionLink = "\(LinkResolver.internalScheme)://question/\(questionID)"
                html += "<h1 class=\"zpp-title\"><a href=\"\(questionLink)\">\(HTML.escape(detail.title))</a></h1>"
                let counts = [
                    detail.questionAnswerCount.map { "\(Format.count($0)) 个回答" },
                    detail.questionFollowerCount.map { "\(Format.count($0)) 个关注" },
                ].compactMap { $0 }
                html += "<a class=\"zpp-question-entry\" href=\"\(questionLink)\">\((["知乎"] + (counts.isEmpty ? ["查看全部回答"] : counts)).joined(separator: " · ")) ›</a>"
            } else {
                html += "<h1 class=\"zpp-title\">\(HTML.escape(detail.title))</h1>"
            }
        }
        return html
    }

    private func documentBody(_ detail: ContentDetail, showsTitle: Bool, showsAuthor: Bool = true) -> String {
        var html = showsTitle ? titleHTML(detail) : ""
        if showsAuthor { html += authorHeaderHTML(detail.author) }
        if detail.isPaid, detail.html.isEmpty {
            html += "<p>这是知乎盐选付费内容，Zhihu++ 不提供付费内容的阅读。</p>"
        }
        html += detail.html
        var meta: [String] = []
        if detail.updatedTime > 0, detail.updatedTime != detail.createdTime {
            meta.append("编辑于 \(Format.dateString(detail.updatedTime))")
        } else if detail.createdTime > 0 {
            meta.append("发布于 \(Format.dateString(detail.createdTime))")
        }
        if let ip = detail.ipInfo { meta.append(HTML.escape(ip)) }
        if !meta.isEmpty {
            html += "<div class=\"zpp-meta\">\(meta.joined(separator: " · "))</div>"
        }
        return html
    }

    private func answerHTML(_ detail: ContentDetail, showsTitle: Bool) -> String {
        let id = HTML.escape(detail.id)
        func button(_ action: String, _ label: String, _ content: String, css: String = "", disabled: Bool = false, pressed: Bool? = nil) -> String {
            let state = pressed.map { " aria-pressed=\"\($0)\"" } ?? ""
            return "<button class=\"\(css)\" data-reader-action=\"\(action)\" data-answer-id=\"\(id)\" aria-label=\"\(HTML.escape(label))\"\(state)\(disabled ? " disabled" : "")>\(content)</button>"
        }
        var authorHTML = authorHeaderHTML(detail.author)
        if let author = detail.author, author.profileKey != nil {
            let follow = author.isFollowing ? "已关注" : "+ 关注"
            authorHTML += button("follow", author.isFollowing ? "取消关注作者" : "关注作者", follow,
                                 css: "zpp-follow\(author.isFollowing ? " is-following" : "")",
                                 disabled: followingIDs.contains(author.id), pressed: author.isFollowing)
        }
        authorHTML += button("share", "分享回答", Self.answerIcon("share"), css: "zpp-share")
        let up = button("up", "\(detail.voteState == .up ? "取消赞同" : "赞同")，\(detail.voteupCount)",
                        Self.answerIcon("up") + "<span class=\"zpp-count\">\(Format.compactCount(detail.voteupCount))</span>",
                        css: detail.voteState == .up ? "is-selected" : "", disabled: votingIDs.contains(detail.id), pressed: detail.voteState == .up)
        let down = button("down", detail.voteState == .down ? "取消反对" : "反对", Self.answerIcon("down"),
                          css: detail.voteState == .down ? "is-selected" : "", disabled: votingIDs.contains(detail.id), pressed: detail.voteState == .down)
        let favorite = button("favorite", "收藏，\(detail.favoriteCount)", Self.answerIcon("star") + (detail.favoriteCount > 0 ? "<span class=\"zpp-count\">\(Format.compactCount(detail.favoriteCount))</span>" : ""),
                              css: detail.isFavorited == true ? "is-favorited" : "", pressed: detail.isFavorited == true)
        let comments = button("comments", "评论，\(detail.commentCount)", Self.answerIcon("comments") + (detail.commentCount > 0 ? "<span class=\"zpp-count\">\(Format.compactCount(detail.commentCount))</span>" : ""))
        let prompt = button("comments", "加入讨论", "加入讨论吧", css: "zpp-comment-prompt")
        let more = button("more", "更多回答操作", Self.answerIcon("more"), css: "zpp-more")
        return """
        <article class="zpp-answer">
          \(showsTitle ? titleHTML(detail) : "")
          <div class="zpp-answer-header" data-zpp-update="header">\(authorHTML)</div>
          <div class="zpp-vote-hint" data-zpp-update="votes">\(Format.count(detail.voteupCount)) 人赞同了该回答</div>
          <div class="zpp-answer-body">\(documentBody(detail, showsTitle: false, showsAuthor: false))</div>
          <div class="zpp-answer-actions" data-zpp-update="actions">\(prompt)\(up)\(down)\(favorite)\(comments)\(more)</div>
        </article>
        """
    }

    private static func answerIcon(_ name: String) -> String {
        let path: String
        switch name {
        case "up": path = "<path d='M12 3.5 22 21H2Z'/>"
        case "down": path = "<path d='m12 21-10-17.5h20Z'/>"
        case "star": path = "<path d='m12 2.5 3 6.1 6.7 1-4.9 4.8 1.2 6.7-6-3.2-6 3.2 1.2-6.7-4.9-4.8 6.7-1Z'/>"
        case "comments": path = "<path d='M21 11.5a9 9 0 0 1-9 9c-1.5 0-3-.4-4.2-1L3 21l1.5-4.8A9 9 0 1 1 21 11.5Z'/>"
        case "share": path = "<path d='m14 3 8 7-8 7v-4C8 13 5 15 2 20c0-9 5-13 12-13Z'/>"
        default: path = "<circle cx='12' cy='5' r='1' fill='currentColor'/><circle cx='12' cy='12' r='1' fill='currentColor'/><circle cx='12' cy='19' r='1' fill='currentColor'/>"
        }
        return "<svg viewBox='0 0 24 24' width='24' height='24' fill='none' stroke='currentColor' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round' aria-hidden='true'>\(path)</svg>"
    }

    private static let answerCSS = """
    body { padding: 0; background: #f5f6f8; }
    .zpp-section + .zpp-section { border-top: 8px solid #f5f6f8; }
    .zpp-answer { padding: 20px 16px 10px; background: #fff; }
    .zpp-answer .zpp-title { font-size: 1.25em; margin-bottom: 10px; }
    .zpp-answer .zpp-question-entry { margin-bottom: 24px; color: #8c9099; }
    .zpp-answer-header { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
    .zpp-answer-header .zpp-author { flex: 1; min-width: 0; margin: 0; gap: 10px; }
    .zpp-answer-header .zpp-author > div { min-width: 0; }
    .zpp-answer-header .name { font-size: .9em; line-height: 1.5; }
    .zpp-answer-header .headline { font-size: .72em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; line-height: 1.5; }
    .zpp-answer-header .zpp-author img { flex: 0 0 36px; width: 36px; height: 36px; }
    .zpp-answer button { font-family: inherit; -webkit-appearance: none; border: 0; margin: 0; cursor: pointer; -webkit-tap-highlight-color: transparent; }
    .zpp-answer button:active { opacity: .5; }
    .zpp-answer button:disabled { opacity: .4; }
    .zpp-answer .zpp-follow { flex-shrink: 0; color: #1681ff; background: #edf4ff; border-radius: 20px; font-size: 14px; font-weight: 600; padding: 0 14px; min-height: 32px; }
    .zpp-answer .zpp-follow.is-following { color: #8c9099; background: #f6f6f8; }
    .zpp-answer .zpp-share { display: flex; align-items: center; justify-content: center; width: 36px; height: 44px; padding: 0; background: transparent; color: #777a80; }
    .zpp-vote-hint { color: #9296a0; font-size: .75em; margin-bottom: 12px; }
    .zpp-answer-body { line-height: 1.8; }
    .zpp-answer-body > p:last-of-type { margin-bottom: 0; }
    .zpp-answer .zpp-meta { font-size: .75em; color: #9296a0; margin-top: 18px; margin-bottom: 8px; }
    .zpp-answer-actions { display: flex; align-items: center; gap: 2px; margin-top: 8px; }
    .zpp-answer-actions button { display: flex; position: relative; justify-content: center; align-items: center; flex: 0 0 44px; min-width: 0; height: 44px; padding: 0; background: transparent; color: #777a80; }
    .zpp-answer-actions .zpp-comment-prompt { display: block; text-align: left; padding: 0 14px; flex: 1; margin-right: 10px; background: #f6f6f8; border-radius: 22px; height: 34px; color: #969aa4; font-size: 12px; white-space: nowrap; }
    .zpp-count { position: absolute; top: 0; left: 27px; font-size: 10px; font-weight: 500; line-height: 14px; background: #fff; padding: 0 2px; }
    .zpp-answer-actions .zpp-more { flex-basis: 24px; }
    .zpp-answer-actions .is-selected { color: #1681ff; }
    .zpp-answer-actions .is-selected svg { fill: #1681ff; }
    .zpp-answer-actions .is-favorited { color: #e6a23c; }
    .zpp-answer-actions .is-favorited svg { fill: #e6a23c; }
    .zpp-stream-status { color: #9296a0; font-size: 13px; text-align: center; padding: 22px 16px 30px; }
    .zpp-stream-status button { border: 0; background: transparent; color: #1681ff; font: inherit; min-height: 44px; padding: 0 12px; }
    @media (max-width: 350px) {
      .zpp-answer { padding-left: 12px; padding-right: 12px; }
      .zpp-answer-actions .zpp-comment-prompt { margin-right: 2px; padding: 0 10px; }
      .zpp-answer-actions button { flex-basis: 40px; }
    }
    @media (prefers-color-scheme: dark) {
      body, .zpp-section + .zpp-section { background: #111; border-color: #111; }
      .zpp-answer, .zpp-count { background: #1c1c1e; }
      .zpp-answer .zpp-follow { background: #142942; color: #69a9ff; }
      .zpp-answer .zpp-follow.is-following, .zpp-answer-actions .zpp-comment-prompt { background: #29292d; color: #a1a1aa; }
      .zpp-answer .zpp-share, .zpp-answer-actions button { color: #aaaab2; }
      .zpp-answer-actions .is-selected { color: #69a9ff; }
      .zpp-answer-actions .is-selected svg { fill: #69a9ff; }
      .zpp-answer-actions .is-favorited { color: #e6a23c; }
    }
    """

    /// 赞同与评论作为主要入口；数字与图标并排，大字体时改为上下排列。
    private func bottomBar(_ detail: ContentDetail) -> some View {
        HStack(spacing: 4) {
            barItem(
                icon: detail.voteState == .up ? "arrowtriangle.up.fill" : "arrowtriangle.up",
                count: detail.voteupCount,
                tint: .accentColor,
                prominent: true
            ) {
                Task { await setVote(detail, to: detail.voteState == .up ? .neutral : .up) }
            }
            .disabled(votingIDs.contains(detail.id))
            .accessibilityLabel(detail.voteState == .up ? "取消赞同" : "赞同")
            if detail.kind == .answer {
                barItem(
                    icon: detail.voteState == .down ? "arrowtriangle.down.fill" : "arrowtriangle.down",
                    count: nil,
                tint: detail.voteState == .down ? .accentColor : Theme.metaText
                ) {
                    Task { await setVote(detail, to: detail.voteState == .down ? .neutral : .down) }
                }
                .disabled(votingIDs.contains(detail.id))
                .accessibilityLabel(detail.voteState == .down ? "取消反对" : "反对")
            }
            barItem(
                icon: detail.isFavorited == true ? "star.fill" : "star",
                count: detail.favoriteCount,
                tint: detail.isFavorited == true ? .orange : Theme.metaText
            ) {
                if account.isLoggedIn {
                    favoriteTarget = detail
                } else {
                    actionError = "请先登录"
                }
            }
            .accessibilityLabel("收藏")
            barItem(icon: "bubble.left", count: detail.commentCount, tint: .primary, prominent: true) {
                router.open(.comments(detail.kind, detail.id))
            }
            .accessibilityLabel("评论")
            if let url = detail.shareURL {
                ShareLink(item: url) {
                    barIcon("square.and.arrow.up", count: nil, tint: Theme.metaText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("分享")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func barItem(icon: String, count: Int?, tint: Color, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            barIcon(icon, count: count, tint: tint, prominent: prominent)
        }
        .buttonStyle(.plain)
        .accessibilityValue(count.map { Format.count($0) } ?? "")
    }

    private func barIcon(_ icon: String, count: Int?, tint: Color, prominent: Bool = false) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 5))
        return layout {
            Image(systemName: icon)
                .font(.system(size: 20, weight: prominent ? .semibold : .regular))
            if let count {
                Text(Format.compactCount(count))
                    .font(.footnote.weight(prominent ? .semibold : .medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 64 : 44)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 4 : 0)
        .background(prominent ? tint.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    private func load() async {
        loadState = .loading
        do {
            var detail = try await ZhihuAPI.contentDetail(kind: kind, id: id)
            // 回答详情里的 question 对象不返回回答数和关注数（include 加 question.answer_count 实测无效），
            // 需要另取问题详情；失败时标题下的入口退化为“查看全部回答”，不影响正文。
            if let questionID = detail.questionID, let question = try? await ZhihuAPI.question(questionID) {
                detail.questionAnswerCount = question.answerCount
                detail.questionFollowerCount = question.followerCount
            }
            navigator.start(with: detail)
            ReadingHistory.shared.record(detail)
            loadState = .loaded(())
        } catch {
            loadState = .failed(error.asZhihuError)
        }
    }

    private func setVote(_ detail: ContentDetail, to newState: VoteState) async {
        guard account.isLoggedIn else {
            actionError = "请先登录"
            return
        }
        guard !votingIDs.contains(detail.id) else { return }
        votingIDs.insert(detail.id)
        defer { votingIDs.remove(detail.id) }
        do {
            let count = try await ZhihuAPI.vote(kind: detail.kind, id: detail.id, state: newState)
            var updated = navigator.answers.first(where: { $0.id == detail.id }) ?? detail
            updated.voteState = newState
            // 反对不影响赞同数；从“已赞同”改为反对或取消时赞同数减一。
            let delta = (newState == .up ? 1 : 0) - (detail.voteState == .up ? 1 : 0)
            updated.voteupCount = count ?? (detail.voteupCount + delta)
            navigator.update(updated)
        } catch {
            actionError = error.asZhihuError.message
        }
    }
}

private struct AnswerShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - 收藏面板

/// 选择收藏夹：勾选即收藏到该收藏夹，再点取消；也可以新建收藏夹。
private struct FavoriteSheet: View {
    let kind: ContentKind
    let id: String
    /// (是否仍在任一收藏夹中, 收藏数变化)
    let onChange: (Bool, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [FavoriteFolder] = []
    @State private var loading = true
    @State private var error: String?
    @State private var busyID: String?
    @State private var newTitle = ""
    @State private var newIsPublic = false
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(folders) { folder in
                    Button {
                        Task { await toggle(folder) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(folder.title).foregroundStyle(.primary)
                                    if !folder.isPublic {
                                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Text("\(folder.itemCount) 条内容").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if busyID == folder.id {
                                ProgressView()
                            } else {
                                Image(systemName: folder.isFavorited ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(folder.isFavorited ? Color.accentColor : Color.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busyID != nil)
                }
                Section("新建收藏夹") {
                    TextField("收藏夹名称", text: $newTitle)
                    Toggle("公开", isOn: $newIsPublic)
                    Button(creating ? "创建中…" : "创建") {
                        Task { await create() }
                    }
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty || creating)
                }
            }
            .navigationTitle("收藏到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            folders = try await ZhihuAPI.favoriteFolders(kind: kind, id: id)
            onChange(folders.contains(where: \.isFavorited), 0)
        } catch {
            self.error = error.asZhihuError.message
        }
    }

    private func toggle(_ folder: FavoriteFolder) async {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        let wasFavorited = folders.contains(where: \.isFavorited)
        busyID = folder.id
        defer { busyID = nil }
        do {
            try await ZhihuAPI.setFavorite(kind: kind, id: id, folderID: folder.id, add: !folder.isFavorited)
            folders[index].isFavorited.toggle()
            folders[index].itemCount += folders[index].isFavorited ? 1 : -1
            let isFavorited = folders.contains(where: \.isFavorited)
            onChange(isFavorited, isFavorited == wasFavorited ? 0 : (isFavorited ? 1 : -1))
        } catch {
            self.error = error.asZhihuError.message
        }
    }

    private func create() async {
        creating = true
        defer { creating = false }
        do {
            try await ZhihuAPI.createFavoriteFolder(title: newTitle.trimmingCharacters(in: .whitespaces), isPublic: newIsPublic)
            newTitle = ""
            folders = try await ZhihuAPI.favoriteFolders(kind: kind, id: id)
        } catch {
            self.error = error.asZhihuError.message
        }
    }
}

// MARK: - 想法

struct PinView: View {
    let id: String
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings
    @State private var state: LoadState<PinDetail> = .loading
    @State private var imageURL: URL?

    var body: some View {
        StatefulView(state: state, retry: { Task { await load() } }) { pin in
            HTMLContentView(
                html: authorHeaderHTML(pin.author) + pin.html
                    + "<div class=\"zpp-meta\">\(Format.dateString(pin.createdTime)) · \(Format.count(pin.likeCount)) 赞</div>",
                fontSize: settings.fontSize,
                onLink: { router.open(url: $0) },
                onImage: { imageURL = $0 }
            )
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button {
                        router.open(.comments(.pin, id))
                    } label: {
                        Label("评论 \(Format.count(pin.commentCount))", systemImage: "bubble.left")
                    }
                    .buttonStyle(.bordered)
                    if let url = URL(string: "https://www.zhihu.com/pin/\(id)") {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .navigationTitle("想法")
        .navigationBarTitleDisplayMode(.inline)
        .imageViewer($imageURL)
        .task {
            if case .loading = state { await load() }
        }
    }

    private func load() async {
        state = .loading
        do {
            let pin = try await ZhihuAPI.pin(id)
            state = .loaded(pin)
            ReadingHistory.shared.record(pin)
            CommentPrefetcher.prefetch(kind: .pin, id: id)
        } catch {
            state = .failed(error.asZhihuError)
        }
    }
}

// MARK: - 问题

struct QuestionView: View {
    let id: String
    @Environment(Router.self) private var router
    @Environment(AccountStore.self) private var account
    @State private var question: QuestionDetail?
    @State private var questionError: ZhihuError?
    @State private var order = "default"
    @State private var expanded = false
    @State private var loader: PagedLoader<FeedItem>

    init(id: String) {
        self.id = id
        _loader = State(initialValue: PagedLoader(
            include: ZhihuAPI.feedInclude,
            initialURL: { ZhihuAPI.questionFeedsURL(id, order: "default") },
            parse: { json in
                ContentFilter.apply(
                    FeedParser.items(from: json["data"].array),
                    options: .init(quality: false, keywords: false)
                )
            }
        ))
    }

    var body: some View {
        List {
            Section {
                header
            }
            Section {
                Picker("排序", selection: $order) {
                    Text("默认排序").tag("default")
                    Text("按时间").tag("updated")
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                ForEach(loader.items) { item in
                    Button {
                        router.open(.answer(item.target.id))
                    } label: {
                        FeedRowView(item: item, showsTitle: false)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { FeedItemMenu(item: item, loader: loader) }
                    .onAppear { loader.onAppear(item) }
                }
                LoadMoreFooter(loader: loader, emptyText: "还没有回答")
            }
        }
        .listStyle(.plain)
        .navigationTitle("问题")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadQuestion()
            await loader.refresh()
        }
        .onChange(of: order) { _, newValue in
            loader.initialURL = { [id] in ZhihuAPI.questionFeedsURL(id, order: newValue) }
            Task { await loader.refresh() }
        }
        .task {
            if question == nil { await loadQuestion() }
            await loader.loadIfNeeded()
        }
        .toolbar {
            if let url = URL(string: "https://www.zhihu.com/question/\(id)") {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if let question {
            VStack(alignment: .leading, spacing: 10) {
                if !question.topics.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(question.topics, id: \.self) { topic in
                                Text(topic)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                Text(question.title).font(.title3.weight(.bold))
                let detail = HTML.plainText(question.detailHTML)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 3)
                        .onTapGesture { expanded.toggle() }
                }
                HStack(spacing: 16) {
                    Text("\(Format.count(question.followerCount)) 关注")
                    Text("\(Format.count(question.visitCount)) 浏览")
                    Text("\(Format.count(question.answerCount)) 回答")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    if account.isLoggedIn {
                        Button(question.isFollowing ? "已关注" : "关注问题") {
                            Task { await toggleFollow() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(question.isFollowing ? .gray : .accentColor)
                    }
                    Button {
                        router.open(.comments(.question, id))
                    } label: {
                        Label("\(Format.count(question.commentCount)) 条评论", systemImage: "bubble.left")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.subheadline)
            }
            .padding(.vertical, 4)
        } else if let questionError {
            ErrorStateView(error: questionError) { Task { await loadQuestion() } }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func loadQuestion() async {
        do {
            question = try await ZhihuAPI.question(id)
            questionError = nil
        } catch {
            questionError = error.asZhihuError
        }
    }

    private func toggleFollow() async {
        guard var question else { return }
        do {
            try await ZhihuAPI.followQuestion(id, follow: !question.isFollowing)
            question.isFollowing.toggle()
            question.followerCount += question.isFollowing ? 1 : -1
            self.question = question
        } catch {
            questionError = error.asZhihuError
        }
    }
}
