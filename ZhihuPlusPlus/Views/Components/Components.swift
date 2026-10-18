import SafariServices
import SwiftUI

struct AvatarView: View {
    let url: URL?
    var size: CGFloat = 32

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct ThumbnailView: View {
    let url: URL?
    var width: CGFloat = 88
    var height: CGFloat = 64

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 作者行：头像、名字、认证徽章（或签名）。
struct AuthorLine: View {
    let author: Author
    var avatarSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 6) {
            AvatarView(url: author.avatarURL, size: avatarSize)
            Text(author.name)
                .font(Theme.Font.author)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            if let badge = author.badgeText {
                HStack(spacing: 3) {
                    if let icon = author.badgeIcon {
                        AsyncImage(url: icon) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                            .frame(width: 14, height: 14)
                    }
                    Text(badge).lineLimit(1)
                }
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.brand)
            } else if !author.headline.isEmpty {
                Text(author.headline)
                    .font(Theme.Font.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// 信息流中的一条内容卡片（外层的白色圆角背景由 `.feedCard()` 提供）。
struct FeedRowView: View {
    let item: FeedItem
    var showsTitle = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let reason = item.filterReason {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash").foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已屏蔽").font(Theme.Font.author).foregroundStyle(.secondary)
                    Text(reason).font(Theme.Font.meta).foregroundStyle(.tertiary)
                }
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let action = item.actionText, !action.isEmpty {
                Text(action).font(Theme.Font.meta).foregroundStyle(Theme.metaText).lineLimit(1)
            }
            if showsTitle, !item.target.title.isEmpty {
                Text(item.target.title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let author = item.target.author, item.target.kind != .question {
                AuthorLine(author: author)
            }
            if !item.target.excerpt.isEmpty {
                Text(item.target.excerpt)
                    .font(Theme.Font.excerpt)
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(4)
                    .lineLimit(3)
            }
            if let thumbnail = item.target.thumbnail {
                AsyncImage(url: thumbnail) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: Theme.imageRadius, style: .continuous))
            }
            HStack(spacing: 6) {
                Text(item.target.kind.label)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                Text(item.metricText ?? item.target.statsText)
                if item.target.isPaid {
                    Text("盐选").foregroundStyle(.orange)
                }
            }
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.metaText)
        }
    }
}

/// 列表底部的加载状态。
struct LoadMoreFooter<Item: Identifiable & Hashable>: View {
    let loader: PagedLoader<Item>
    var emptyText = "暂无内容"

    var body: some View {
        Group {
            if let error = loader.error {
                ErrorStateView(error: error) {
                    Task { loader.hasLoaded && !loader.items.isEmpty ? await loader.loadMore() : await loader.refresh() }
                }
            } else if loader.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if loader.isEnd {
                Text(loader.items.isEmpty ? emptyText : "没有更多了")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 12)
        .plainCardRow()
    }
}

struct ErrorStateView: View {
    let error: ZhihuError
    let retry: () -> Void
    @Environment(Router.self) private var router
    @Environment(AccountStore.self) private var account

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(error.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("重试", action: retry)
                    .buttonStyle(.bordered)
                if let url = error.verificationURL {
                    Button("去验证") { router.verificationURL = url }
                        .buttonStyle(.borderedProminent)
                }
            }
            if error.statusCode == 401 || (error.verificationURL != nil && !account.isLoggedIn) {
                Text("登录后可减少风控拦截，请前往“我的”页面登录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// 页面级的“加载中 / 失败 / 内容”状态。
enum LoadState<Value> {
    case loading
    case failed(ZhihuError)
    case loaded(Value)
}

extension Error {
    var asZhihuError: ZhihuError {
        (self as? ZhihuError) ?? ZhihuError(message: localizedDescription)
    }
}

struct StatefulView<Value, Content: View>: View {
    let state: LoadState<Value>
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            ErrorStateView(error: error, retry: retry).frame(maxHeight: .infinity)
        case .loaded(let value):
            content(value)
        }
    }
}
