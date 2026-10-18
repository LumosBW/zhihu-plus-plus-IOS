import SwiftUI

struct AccountView: View {
    @Environment(AccountStore.self) private var account
    @Environment(Router.self) private var router
    @State private var showLogin = false
    @State private var confirmLogout = false

    var body: some View {
        List {
            Section {
                if let profile = account.profile, account.isLoggedIn {
                    Button {
                        router.open(.people(profile.urlToken ?? profile.id))
                    } label: {
                        HStack(spacing: 14) {
                            AvatarView(url: profile.avatarURL.flatMap(URL.init(string:)), size: 56)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).font(.title3.weight(.semibold))
                                if !profile.headline.isEmpty {
                                    Text(profile.headline).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        showLogin = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 44))
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("登录知乎账号").font(.title3.weight(.semibold))
                                Text("登录后可点赞、评论和查看收藏").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let profile = account.profile, account.isLoggedIn {
                Section {
                    Button {
                        router.open(.collections(profile.urlToken ?? profile.id))
                    } label: {
                        Label("我的收藏", systemImage: "star")
                    }
                }
            }

            Section {
                Button {
                    router.open(.search)
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                Button {
                    router.open(.history)
                } label: {
                    Label("浏览历史", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    router.open(.blocklist)
                } label: {
                    Label("屏蔽设置", systemImage: "hand.raised")
                }
                Button {
                    router.open(.settings)
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }

            if account.isLoggedIn {
                Section {
                    Button("退出登录", role: .destructive) { confirmLogout = true }
                }
            }

            Section {
                Text("Zhihu++ iOS 是开源社区开发的第三方知乎客户端，不由知乎官方开发或运营。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .navigationTitle("我的")
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .confirmationDialog("确定退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { account.logout() }
        }
    }
}

/// 登录流程：先依次确认三条声明（与 Android 版一致），再选择网页登录或手动填写 Cookie。
struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var account
    @State private var noticeStep = 0
    @State private var method = 0
    @State private var cookieText = ""
    @State private var isVerifying = false
    @State private var errorMessage: String?
    @State private var welcomeName: String?
    @State private var webLoginID = UUID()

    private let notices: [(String, String, URL?)] = [
        ("我清楚，本应用由开源社区开发和维护，不由知乎官方开发并运营，也不受到知乎官方的承认或支持，使用本应用的一切后果由我本人承担。我可以在 https://www.zhihu.com/app/ 下载官方应用。",
         "下载官方 App", URL(string: "https://www.zhihu.com/app/")),
        ("在使用本应用的过程中，我承诺遵守知乎使用协议 https://www.zhihu.com/term/zhihu-terms 。我保证在使用过程中不侵犯知乎及其他作者的著作权，使用本应用产生的一切输出仅用于个人浏览和备份，不会进行传播等其他影响作者著作权的行为。",
         "查看协议", URL(string: "https://www.zhihu.com/term/zhihu-terms")),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if noticeStep < notices.count {
                    noticeView(notices[noticeStep])
                } else {
                    loginContent
                }
            }
            .navigationTitle("登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("登录失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { webLoginID = UUID() }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("登录成功", isPresented: Binding(get: { welcomeName != nil }, set: { if !$0 { welcomeName = nil } })) {
                Button("确定") { dismiss() }
            } message: {
                Text("欢迎回来，\(welcomeName ?? "")")
            }
        }
    }

    private func noticeView(_ notice: (String, String, URL?)) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text(notice.0)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
            if let url = notice.2 {
                Link(notice.1, destination: url)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor))
            }
            Button {
                noticeStep += 1
            } label: {
                Text("确认").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    private var loginContent: some View {
        VStack(spacing: 0) {
            Picker("登录方式", selection: $method) {
                Text("网页登录").tag(0)
                Text("Cookie 登录").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            ZStack {
                if method == 0 {
                    WebLoginView { cookies in
                        Task { @MainActor in await login(cookies) }
                    }
                    .id(webLoginID)
                } else {
                    Form {
                        Section {
                            TextEditor(text: $cookieText)
                                .frame(minHeight: 140)
                                .font(.system(.footnote, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } header: {
                            Text("粘贴浏览器中 zhihu.com 的 Cookie")
                        } footer: {
                            Text("格式为 name=value; name2=value2，至少需要包含 z_c0 和 d_c0。Cookie 仅保存在本机钥匙串中。")
                        }
                        Button("登录") {
                            Task { await login(AccountStore.parseCookieString(cookieText)) }
                        }
                        .disabled(cookieText.isEmpty || isVerifying)
                    }
                }
                if isVerifying {
                    ProgressView("正在验证登录…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func login(_ cookies: [String: String]) async {
        guard !isVerifying else { return }
        guard cookies["z_c0"]?.isEmpty == false else {
            errorMessage = "Cookie 中缺少 z_c0"
            return
        }
        isVerifying = true
        defer { isVerifying = false }
        do {
            try await account.login(cookies: cookies)
            welcomeName = account.profile?.name ?? ""
        } catch {
            errorMessage = error.asZhihuError.message
        }
    }
}

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("推荐") {
                Picker("首页默认标签", selection: $settings.recommendationSource) {
                    ForEach(RecommendationSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                ForEach(RecommendationSource.allCases) { source in
                    LabeledContent(source.label, value: source.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("质量过滤", isOn: $settings.qualityFilter)
                Toggle("屏蔽盐选付费内容", isOn: $settings.blockPaidContent)
                Toggle("显示被屏蔽内容的占位", isOn: $settings.showFilteredPlaceholder)
            } header: {
                Text("内容过滤")
            } footer: {
                Text("质量过滤会隐藏首页中低赞且未关注作者的回答、文章，以及回答数和关注数都很少的问题。")
            }
            Section("阅读") {
                Stepper(value: $settings.fontSize, in: 13...26, step: 1) {
                    HStack {
                        Text("正文字号")
                        Spacer()
                        Text("\(Int(settings.fontSize))").foregroundStyle(.secondary)
                    }
                }
            }
            Section("关于") {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                Link("Zhihu++ 开源项目", destination: URL(string: "https://github.com/zly2006/zhihu-plus-plus")!)
            }
        }
        .navigationTitle("设置")
    }
}

struct BlocklistView: View {
    @Environment(AppSettings.self) private var settings
    @State private var newKeyword = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("添加屏蔽词", text: $newKeyword)
                        .onSubmit(add)
                    Button("添加", action: add)
                        .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(settings.blockedKeywords, id: \.self) { keyword in
                    Text(keyword)
                }
                .onDelete { settings.blockedKeywords.remove(atOffsets: $0) }
            } header: {
                Text("屏蔽词")
            } footer: {
                Text("标题或摘要包含屏蔽词的内容将不会出现在信息流中。")
            }
            Section {
                if settings.blockedUsers.isEmpty {
                    Text("长按信息流中的内容可以屏蔽作者").foregroundStyle(.secondary)
                }
                ForEach(settings.blockedUsers) { user in
                    Text(user.name)
                }
                .onDelete { settings.blockedUsers.remove(atOffsets: $0) }
            } header: {
                Text("屏蔽用户")
            }
        }
        .navigationTitle("屏蔽设置")
        .toolbar { EditButton() }
    }

    private func add() {
        settings.addKeyword(newKeyword)
        newKeyword = ""
    }
}
