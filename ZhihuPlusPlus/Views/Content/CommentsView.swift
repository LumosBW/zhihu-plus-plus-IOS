import SwiftUI

struct CommentRowView: View {
    let comment: Comment
    var showsChildren = true
    var onLike: (Comment) -> Void = { _ in }
    var onReply: (Comment) -> Void = { _ in }
    var onOpenChildren: (Comment) -> Void = { _ in }
    @Environment(Router.self) private var router
    @State private var viewingImage: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if let key = comment.author?.profileKey { router.open(.people(key)) }
            } label: {
                AvatarView(url: comment.author?.avatarURL, size: 34)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(comment.author?.name ?? "匿名用户")
                        .font(.subheadline.weight(.semibold))
                        .superscriptTag(comment.authorTag)
                    if let reply = comment.replyToName {
                        Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7)).foregroundStyle(.tertiary)
                        Text(reply)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .superscriptTag(comment.replyToTag)
                    }
                }
                .lineLimit(1)

                if !comment.text.isEmpty {
                    CommentEmoji.text(comment.text, size: 20)
                        .font(.body)
                        .textSelection(.enabled)
                }

                if let imageURL = comment.imageURL {
                    Button {
                        viewingImage = imageURL
                    } label: {
                        AsyncImage(url: imageURL) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit()
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary)
                                    .frame(width: 120, height: 90)
                                    .overlay { Image(systemName: phase.error == nil ? "photo" : "exclamationmark.triangle").foregroundStyle(.secondary) }
                            }
                        }
                        .frame(maxWidth: 220, maxHeight: 160, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 14) {
                    Text([Format.relativeTime(comment.createdTime), comment.ipText].compactMap { $0 }.joined(separator: " · "))
                    Spacer()
                    Button {
                        onReply(comment)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left")
                    }
                    Button {
                        onLike(comment)
                    } label: {
                        Label("\(comment.likeCount)", systemImage: comment.liked ? "heart.fill" : "heart")
                            .foregroundStyle(comment.liked ? Color.red : Color.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)

                if showsChildren, comment.childCommentCount > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(comment.childComments.prefix(2)) { child in
                            Text("\(Text(verbatim: child.author?.name ?? "").fontWeight(.semibold))\(Self.inlineTag(child.authorTag))\(Text(verbatim: child.replyToName.map { " 回复 \($0)" } ?? "").foregroundColor(.secondary))\(Self.inlineTag(child.replyToTag))：\(CommentEmoji.text(child.text + (child.imageURL == nil ? "" : " [图片]"), size: 17))")
                                .font(.subheadline)
                                .lineLimit(3)
                        }
                        Button("查看全部 \(comment.childCommentCount) 条回复") {
                            onOpenChildren(comment)
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            // 分割线默认对齐行内某个 Text 的起点，会落在右侧点赞数上，只剩一小截；显式对齐到评论正文列。
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        // 默认行距加上下内边距让评论之间空得太开，收紧到上下各 10pt。
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .imageViewer($viewingImage)
    }
}

extension CommentRowView {
    /// 楼中楼预览是一整段 Text，标签只能以小号上标文字拼进去。
    static func inlineTag(_ tag: String?) -> Text {
        guard let tag else { return Text(verbatim: "") }
        return Text(verbatim: " \(tag)")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(Theme.brand)
            .baselineOffset(6)
    }
}

extension View {
    /// 在名字右上角挂一个小标签（如“作者”），不改变名字本身的位置。
    func superscriptTag(_ tag: String?) -> some View {
        HStack(alignment: .top, spacing: 2) {
            self
            if let tag {
                Text(tag)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.brand.opacity(0.12), in: Capsule())
                    .offset(y: -5)
            }
        }
    }
}

/// 评论预取：回答 / 文章 / 想法一加载出来，就在后台取好评论第一页（默认排序）和前几条评论的楼中楼预览，
/// 点进评论区时直接显示，不再先转圈再出内容。缓存 5 分钟，最多保留 30 条内容的评论。
@MainActor
enum CommentPrefetcher {
    struct Page {
        let json: JSONValue
        let childPreviews: [String: [Comment]]
        let date: Date
    }

    private static var pages: [String: Page] = [:]
    private static var inflight: [String: Task<Void, Never>] = [:]
    private static var order: [String] = []
    /// 只为前几条评论预取楼中楼，大约是进入评论区第一屏能看到的数量。
    private static let previewCount = 4

    private static func key(_ kind: ContentKind, _ id: String) -> String { "\(kind.rawValue):\(id)" }

    static func prefetch(kind: ContentKind, id: String) {
        let key = key(kind, id)
        if let page = pages[key], Date().timeIntervalSince(page.date) < 300 { return }
        guard inflight[key] == nil else { return }
        inflight[key] = Task {
            defer { inflight[key] = nil }
            guard let json = try? await ZhihuClient.shared.json(.get, ZhihuAPI.rootCommentsURL(kind: kind, id: id, order: "score")) else { return }
            var previews: [String: [Comment]] = [:]
            let needing = json["data"].array.compactMap(Comment.init(json:))
                .prefix(previewCount)
                .filter { $0.childComments.count < min(2, $0.childCommentCount) }
            await withTaskGroup(of: (String, [Comment])?.self) { group in
                for comment in needing {
                    group.addTask {
                        guard let child = try? await ZhihuClient.shared.json(.get, ZhihuAPI.childCommentsURL(comment.id) + "?limit=2") else { return nil }
                        return (comment.id, Array(child["data"].array.compactMap(Comment.init(json:)).prefix(2)))
                    }
                }
                for await result in group {
                    if let (id, children) = result { previews[id] = children }
                }
            }
            pages[key] = Page(json: json, childPreviews: previews, date: Date())
            order.removeAll { $0 == key }
            order.append(key)
            if order.count > 30 { pages[order.removeFirst()] = nil }
        }
    }

    /// 取出可用的预取结果；还在请求中时等它完成。
    static func page(kind: ContentKind, id: String) async -> Page? {
        let key = key(kind, id)
        if let task = inflight[key] { await task.value }
        guard let page = pages[key], Date().timeIntervalSince(page.date) < 300 else { return nil }
        return page
    }

    static func cachedPage(kind: ContentKind, id: String) -> Page? {
        guard let page = pages[key(kind, id)], Date().timeIntervalSince(page.date) < 300 else { return nil }
        return page
    }
}

extension PagedLoader where Item == Comment {
    /// 用预取结果填充评论列表，并带上已取好的楼中楼预览。
    func seed(with page: CommentPrefetcher.Page) {
        seed(with: page.json)
        for (id, children) in page.childPreviews {
            if var comment = items.first(where: { $0.id == id }) {
                comment.childComments = children
                update(comment)
            }
        }
    }
}

/// 评论输入栏与评论列表的公共逻辑。
@MainActor
@Observable
final class CommentActions {
    var draft = ""
    var replyTarget: Comment?
    var isSending = false
    var error: String?
    @ObservationIgnored private var previewRequested = Set<String>()

    /// 楼中楼预览：root_comment 接口最多只附带 1 条（经常是 0 条）子评论，
    /// 不够两条时按需请求该评论的子评论列表补齐。
    func loadChildPreview(_ comment: Comment, loader: PagedLoader<Comment>) async {
        guard comment.childComments.count < min(2, comment.childCommentCount),
              previewRequested.insert(comment.id).inserted,
              let json = try? await ZhihuClient.shared.json(.get, ZhihuAPI.childCommentsURL(comment.id) + "?limit=2"),
              var current = loader.items.first(where: { $0.id == comment.id }) else { return }
        current.childComments = Array(json["data"].array.compactMap(Comment.init(json:)).prefix(2))
        loader.update(current)
    }

    func toggleLike(_ comment: Comment, loader: PagedLoader<Comment>) async {
        var updated = comment
        updated.liked.toggle()
        updated.likeCount += updated.liked ? 1 : -1
        loader.update(updated)
        do {
            try await ZhihuAPI.likeComment(comment.id, like: updated.liked)
        } catch {
            loader.update(comment)
            self.error = error.asZhihuError.message
        }
    }

    func send(kind: ContentKind, id: String, loader: PagedLoader<Comment>) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            if let comment = try await ZhihuAPI.postComment(kind: kind, id: id, text: text, replyTo: replyTarget?.id) {
                loader.insert(comment)
            }
            draft = ""
            replyTarget = nil
        } catch {
            self.error = error.asZhihuError.message
        }
    }
}

struct CommentInputBar: View {
    @Bindable var actions: CommentActions
    let onSend: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let target = actions.replyTarget {
                HStack {
                    Text("回复 \(target.author?.name ?? "")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        actions.replyTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                TextField("友善评论，理性发言", text: $actions.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                Button {
                    onSend()
                } label: {
                    if actions.isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(actions.isSending || actions.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: actions.replyTarget) { _, target in
            if target != nil { focused = true }
        }
    }
}

struct CommentsView: View {
    let kind: ContentKind
    let id: String
    @Environment(Router.self) private var router
    @Environment(AccountStore.self) private var account
    @State private var order = "score"
    @State private var actions = CommentActions()
    @State private var loader: PagedLoader<Comment>

    init(kind: ContentKind, id: String) {
        self.kind = kind
        self.id = id
        let loader = PagedLoader<Comment>(
            initialURL: { ZhihuAPI.rootCommentsURL(kind: kind, id: id, order: "score") },
            parse: { json in json["data"].array.compactMap(Comment.init(json:)) }
        )
        // 预取已完成时在创建列表时就填好数据，第一帧就有内容。
        if let page = CommentPrefetcher.cachedPage(kind: kind, id: id) {
            loader.seed(with: page)
        }
        _loader = State(initialValue: loader)
    }

    var body: some View {
        List {
            Picker("排序", selection: $order) {
                Text("默认").tag("score")
                Text("最新").tag("ts")
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            ForEach(loader.items) { comment in
                CommentRowView(
                    comment: comment,
                    onLike: { target in Task { await actions.toggleLike(target, loader: loader) } },
                    onReply: { actions.replyTarget = $0 },
                    onOpenChildren: { router.open(.childComments($0.id)) }
                )
                .onAppear { loader.onAppear(comment) }
                .task(id: comment.id) { await actions.loadChildPreview(comment, loader: loader) }
            }
            LoadMoreFooter(loader: loader, emptyText: "还没有评论")
        }
        .listStyle(.plain)
        .navigationTitle("评论")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loader.refresh() }
        .task {
            // 预取还在进行中时等它完成，避免重复请求。
            if !loader.hasLoaded, let page = await CommentPrefetcher.page(kind: kind, id: id) {
                loader.seed(with: page)
            }
            await loader.loadIfNeeded()
        }
        .onChange(of: order) { _, newValue in
            loader.initialURL = { [kind, id] in ZhihuAPI.rootCommentsURL(kind: kind, id: id, order: newValue) }
            Task { await loader.refresh() }
        }
        .safeAreaInset(edge: .bottom) {
            if account.isLoggedIn {
                CommentInputBar(actions: actions) {
                    Task { await actions.send(kind: kind, id: id, loader: loader) }
                }
            }
        }
        .alert("操作失败", isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actions.error ?? "")
        }
    }
}

struct ChildCommentsView: View {
    let commentID: String
    @State private var actions = CommentActions()
    @State private var loader: PagedLoader<Comment>

    init(commentID: String) {
        self.commentID = commentID
        _loader = State(initialValue: PagedLoader(
            initialURL: { ZhihuAPI.childCommentsURL(commentID) },
            parse: { json in json["data"].array.compactMap(Comment.init(json:)) }
        ))
    }

    var body: some View {
        List {
            ForEach(loader.items) { comment in
                CommentRowView(
                    comment: comment,
                    showsChildren: false,
                    onLike: { target in Task { await actions.toggleLike(target, loader: loader) } }
                )
                .onAppear { loader.onAppear(comment) }
            }
            LoadMoreFooter(loader: loader, emptyText: "没有回复")
        }
        .listStyle(.plain)
        .navigationTitle("回复")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loader.refresh() }
        .task { await loader.loadIfNeeded() }
        .alert("操作失败", isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actions.error ?? "")
        }
    }
}
