import SwiftUI
import WebKit

/// 网页登录：在独立的非持久化 WKWebView 中打开知乎登录页，
/// 一旦出现 `z_c0` Cookie 即视为登录成功，交给 `AccountStore` 校验。
/// 对应 Android 版 `WebLoginPane`。
struct WebLoginView: UIViewRepresentable {
    let onCookies: ([String: String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCookies: onCookies) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.webView = webView
        webView.load(URLRequest(url: URL(string: "https://www.zhihu.com/signin?next=%2F")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let onCookies: ([String: String]) -> Void
        weak var webView: WKWebView?
        private var delivered = false

        init(onCookies: @escaping ([String: String]) -> Void) {
            self.onCookies = onCookies
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            check(cookieStore)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            check(webView.configuration.websiteDataStore.httpCookieStore)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // 知乎网页会尝试唤起 zhihu:// 打开官方 App，直接拦截。
            decisionHandler(navigationAction.request.url?.scheme == "zhihu" ? .cancel : .allow)
        }

        private func check(_ store: WKHTTPCookieStore) {
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.delivered else { return }
                var result: [String: String] = [:]
                for cookie in cookies where cookie.domain.hasSuffix("zhihu.com") {
                    result[cookie.name] = cookie.value
                }
                guard let token = result["z_c0"], !token.isEmpty else { return }
                self.delivered = true
                self.onCookies(result)
            }
        }
    }
}

/// 风控验证页：把当前 Cookie 注入 WKWebView，打开知乎返回的验证地址，
/// 关闭时把验证后得到的新 Cookie 同步回客户端。对应 Android 版 `configureRiskControlWebView`。
struct VerificationView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var store = WKWebsiteDataStore.nonPersistent()

    var body: some View {
        NavigationStack {
            VerificationWebView(url: url, store: store)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("安全验证")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            syncCookies { dismiss() }
                        }
                    }
                }
        }
    }

    private func syncCookies(completion: @escaping () -> Void) {
        store.httpCookieStore.getAllCookies { cookies in
            var result: [String: String] = [:]
            for cookie in cookies where cookie.domain.hasSuffix("zhihu.com") {
                result[cookie.name] = cookie.value
            }
            ZhihuClient.shared.cookies.merge(result)
            completion()
        }
    }
}

private struct VerificationWebView: UIViewRepresentable {
    let url: URL
    let store: WKWebsiteDataStore

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"
        let cookies = ZhihuClient.shared.cookies.all.compactMap { name, value in
            HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: ".zhihu.com",
                .path: "/",
            ])
        }
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.httpCookieStore.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
