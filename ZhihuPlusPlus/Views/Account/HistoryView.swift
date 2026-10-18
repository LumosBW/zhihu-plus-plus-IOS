import SwiftUI

/// 浏览历史：「本机」是在 Zhihu++ 里读过的内容，「知乎」是账号的在线浏览记录（官方 App / 网页）。
struct HistoryView: View {
    private enum Source: String, CaseIterable {
        case local = "本机"
        case online = "知乎"
    }

    @Environment(Router.self) private var router
    @Environment(AccountStore.self) private var account
    @State private var source: Source = .local
    @State private var history = ReadingHistory.shared
    @State private var confirmClear = false
    @State private var actionError: String?
    @State private var online = PagedLoader<OnlineHistoryEntry>(
        initialURL: { OnlineHistoryEntry.listURL },
        parse: { json in json["data"].array.compactMap(OnlineHistoryEntry.init(json:)) }
    )

    var body: some View {
        List {
            Picker("来源", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .plainCardRow()

            switch source {
            case .local: localRows
            case .online: onlineRows
            }
        }
        .cardListStyle()
        .navigationTitle("浏览历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if source == .local, !history.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { confirmClear = true }
                }
            }
        }
        .confirmationDialog("清空本机浏览历史？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { history.clear() }
        }
        .alert("操作失败", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .refreshable {
            if source == .online { await online.refresh() }
        }
        .onChange(of: source) { _, newValue in
            if newValue == .online, account.isLoggedIn { Task { await online.loadIfNeeded() } }
        }
    }

    // MARK: 本机

    @ViewBuilder
    private var localRows: some View {
        if history.entries.isEmpty {
            Text("在 Zhihu++ 里读过的回答、文章和想法会出现在这里")
                .font(Theme.Font.excerpt)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .plainCardRow()
        }
        ForEach(groupedLocal, id: \.title) { group in
            Text(group.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .plainCardRow()
            ForEach(group.entries) { entry in
                Button {
                    if let route = entry.route { router.open(route) }
                } label: {
                    HistoryCard(
                        title: entry.title,
                        excerpt: entry.excerpt,
                        authorName: entry.authorName,
                        avatarURL: entry.avatarURL,
                        meta: "\(entry.contentKind.label) · \(Self.timeText(entry.readAt))"
                    )
                    .feedCard()
                }
                .buttonStyle(.plain)
                .plainCardRow()
                .swipeActions {
                    Button("删除", role: .destructive) { history.remove(entry) }
                }
                .contextMenu {
                    Button("删除这条记录", systemImage: "trash", role: .destructive) { history.remove(entry) }
                }
            }
        }
    }

    private var groupedLocal: [(title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        var groups: [(title: String, entries: [HistoryEntry])] = []
        for entry in history.entries {
            let title: String
            if calendar.isDateInToday(entry.readAt) {
                title = "今天"
            } else if calendar.isDateInYesterday(entry.readAt) {
                title = "昨天"
            } else {
                title = formatter.string(from: entry.readAt)
            }
            if groups.last?.title == title {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((title, [entry]))
            }
        }
        return groups
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: 知乎

    @ViewBuilder
    private var onlineRows: some View {
        if !account.isLoggedIn {
            Text("登录后可查看知乎账号的浏览记录")
                .font(Theme.Font.excerpt)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .plainCardRow()
        } else {
            Text("知乎账号在官方 App 和网页上的浏览记录。Zhihu++ 不上报阅读记录，这里看不到在本应用里读过的内容。")
                .font(Theme.Font.meta)
                .foregroundStyle(.tertiary)
                .plainCardRow()
            ForEach(online.items) { entry in
                Button {
                    if let url = entry.url { router.open(url: url) }
                } label: {
                    HistoryCard(
                        title: entry.title,
                        excerpt: entry.summary,
                        authorName: entry.authorName,
                        avatarURL: nil,
                        meta: [entry.detail, entry.readTime > 0 ? Format.relativeTime(entry.readTime) : nil]
                            .compactMap { $0 }.joined(separator: " · ")
                    )
                    .feedCard()
                }
                .buttonStyle(.plain)
                .plainCardRow()
                .onAppear { online.onAppear(entry) }
                .swipeActions {
                    Button("删除", role: .destructive) { Task { await deleteOnline(entry) } }
                }
                .contextMenu {
                    Button("删除这条记录", systemImage: "trash", role: .destructive) { Task { await deleteOnline(entry) } }
                }
            }
            LoadMoreFooter(loader: online, emptyText: "没有浏览记录")
                .task { await online.loadIfNeeded() }
        }
    }

    private func deleteOnline(_ entry: OnlineHistoryEntry) async {
        do {
            try await entry.delete()
            online.remove { $0.id == entry.id }
        } catch {
            actionError = error.asZhihuError.message
        }
    }
}

private struct HistoryCard: View {
    let title: String
    let excerpt: String
    let authorName: String?
    let avatarURL: URL?
    let meta: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(Theme.Font.cardTitle)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let authorName {
                HStack(spacing: 6) {
                    if let avatarURL { AvatarView(url: avatarURL, size: 18) }
                    Text(authorName).font(Theme.Font.author).lineLimit(1)
                }
            }
            if !excerpt.isEmpty {
                Text(excerpt)
                    .font(Theme.Font.excerpt)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(meta)
                .font(Theme.Font.meta)
                .foregroundStyle(.tertiary)
        }
    }
}
