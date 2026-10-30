import Foundation
import Observation

enum Route: Hashable {
    case answer(String)
    case article(String)
    case question(String)
    case pin(String)
    case people(String)
    case comments(ContentKind, String)
    case childComments(String)
    case collections(String)
    case collection(String, String)
    case dailyStory(String, String)
    case search
    case settings
    case blocklist
    case history
    case web(URL)
}

/// 每个 Tab 独立的导航栈。
@MainActor
@Observable
final class Router {
    var path: [Route] = []
    /// 站外链接用应用内 Safari 打开。
    var safariURL: URL?
    /// 风控验证页面。
    var verificationURL: URL?
    /// 每次加一，根页面的列表收到后滚回顶部（在已选中的 Tab 上再点一次时触发）。
    private(set) var scrollToTopRequest = 0

    func open(_ route: Route) {
        if case .web(let url) = route {
            safariURL = url
        } else {
            path.append(route)
        }
    }

    func open(url: URL) {
        open(LinkResolver.route(for: url) ?? .web(url))
    }

    func popToRoot() {
        path.removeAll()
    }

    func scrollToTop() {
        scrollToTopRequest += 1
    }
}

/// 把知乎链接解析为应用内页面，对应 Android 版 `resolveContent`。
enum LinkResolver {
    static let internalScheme = "zhihupp"

    static func route(for url: URL) -> Route? {
        if url.scheme == internalScheme {
            return internalRoute(url)
        }
        guard let host = url.host?.lowercased() else { return nil }

        // 站外跳转中转：https://link.zhihu.com/?target=xxx
        if host == "link.zhihu.com",
           let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "target" })?.value,
           let targetURL = URL(string: target) {
            return route(for: targetURL) ?? .web(targetURL)
        }

        guard host.hasSuffix("zhihu.com") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)

        if host.hasPrefix("zhuanlan."), parts.count >= 2, parts[0] == "p" {
            return .article(parts[1])
        }
        if host == "api.zhihu.com" || host == "www.zhihu.com" || host == "zhihu.com" {
            let normalized = parts.first == "api" ? Array(parts.drop(while: { $0 != "answers" && $0 != "articles" && $0 != "questions" && $0 != "pins" && $0 != "people" && $0 != "members" })) : parts
            guard let first = normalized.first else { return nil }
            switch first {
            case "question", "questions":
                if normalized.count >= 4, normalized[2] == "answer" || normalized[2] == "answers" {
                    return .answer(normalized[3])
                }
                if normalized.count >= 2 { return .question(normalized[1]) }
            case "answer", "answers":
                if normalized.count >= 2 { return .answer(normalized[1]) }
            case "article", "articles", "p":
                if normalized.count >= 2 { return .article(normalized[1]) }
            case "pin", "pins":
                if normalized.count >= 2 { return .pin(normalized[1]) }
            case "people", "member", "members", "org":
                if normalized.count >= 2 { return .people(normalized[1]) }
            default:
                break
            }
        }
        return nil
    }

    /// 正文模板中使用的内部链接：zhihupp://question/123、zhihupp://people/token。
    private static func internalRoute(_ url: URL) -> Route? {
        guard let host = url.host else { return nil }
        let value = url.path.split(separator: "/").first.map(String.init) ?? ""
        switch host {
        case "question": return .question(value)
        case "people": return .people(value)
        case "answer": return .answer(value)
        case "article": return .article(value)
        default: return nil
        }
    }
}
