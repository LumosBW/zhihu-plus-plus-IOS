import Foundation

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

struct ZhihuError: LocalizedError {
    let message: String
    var statusCode: Int?
    /// 知乎风控（错误码 40352）返回的人机验证页面，用户在网页中完成验证后即可恢复访问。
    var verificationURL: URL?

    var errorDescription: String? { message }
}

/// 知乎域 Cookie 容器，对应 Android 版的 `ZhihuCookieStorage`。
///
/// 系统 `HTTPCookieStorage` 会按域名/路径分发 Cookie，而知乎 API 分布在 www/api/zhuanlan 多个子域，
/// 这里与 Android 版保持一致：把 `*.zhihu.com` 下的 Cookie 统一保存，并在每个请求上整体发送。
final class CookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]
    private let keychainAccount = "zhihu.cookies"

    init() {
        if let data = Keychain.data(for: keychainAccount),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            storage = saved
        } else {
            storage = [:]
        }
    }

    var all: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    subscript(name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    var headerValue: String {
        all.filter { !$0.value.isEmpty }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "; ")
    }

    func merge(_ cookies: [String: String]) {
        lock.lock()
        for (name, value) in cookies {
            // 知乎在部分接口上会下发空的 z_c0，覆盖后会导致掉登录。
            // 参见 https://github.com/zly2006/zhihu-plus-plus/issues/25#issuecomment-3311926550
            if name == "z_c0", value.isEmpty { continue }
            storage[name] = value
        }
        lock.unlock()
        persist()
    }

    func replaceAll(_ cookies: [String: String]) {
        lock.lock()
        storage = cookies
        lock.unlock()
        persist()
    }

    func clear() {
        replaceAll([:])
    }

    private func persist() {
        let snapshot = all
        Keychain.set(try? JSONEncoder().encode(snapshot), for: keychainAccount)
    }
}

/// 知乎 HTTP 客户端：负责 Cookie、UA、`x-zse-96` 签名与错误解析。
final class ZhihuClient: @unchecked Sendable {
    static let shared = ZhihuClient()

    /// 与 Android 版 `DEFAULT_ZHIHU_USER_AGENT` 保持一致。
    static let userAgent = "Mozilla/5.0 (X11; U; Linux x86_64; en-US) AppleWebKit/540.0 (KHTML, like Gecko) Ubuntu/10.10 Chrome/9.1.0.0 Safari/540.0"

    /// 官方安卓 App 10.61.0 的请求头与 UA，取自 Android 版 `AccountData.ANDROID_HEADERS` / `ANDROID_USER_AGENT`。
    static let androidAppHeaders = [
        "x-api-version": "3.1.8",
        "x-app-version": "10.61.0",
        "x-app-za": "OS=Android&Release=12&Model=sdk_gphone64_arm64&VersionName=10.61.0&VersionCode=26107&Product=com.zhihu.android&Width=1440&Height=2952&Installer=%E7%81%B0%E5%BA%A6&DeviceType=AndroidPhone&Brand=google",
        "User-Agent": "com.zhihu.android/Futureve/10.61.0 Mozilla/5.0 (Linux; Android 12; sdk_gphone64_arm64 Build/SE1A.220630.001.A1; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/57.0.1000.10 Mobile Safari/537.36",
    ]

    let cookies = CookieJar()
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 拼出最终请求 URL。签名必须基于实际发送的字符串计算，因此 URL 只在这里构造一次。
    static func buildURLString(_ url: String, include: String?) -> String {
        var result = url
        if result.hasPrefix("http://") {
            result = "https://" + result.dropFirst("http://".count)
        }
        if let include, !include.isEmpty, !result.contains("include=") {
            result += (result.contains("?") ? "&" : "?") + "include=" + percentEncode(include)
        }
        return result
    }

    @discardableResult
    func send(
        _ method: HTTPMethod = .get,
        _ url: String,
        include: String? = nil,
        json: [String: Any]? = nil,
        form: [String: String]? = nil,
        multipart: [String: String]? = nil,
        headers: [String: String] = [:],
        sign: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let urlString = Self.buildURLString(url, include: include)
        guard let requestURL = URL(string: urlString) else {
            throw ZhihuError(message: "无效的地址：\(urlString)")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method.rawValue
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.zhihu.com/", forHTTPHeaderField: "Referer")
        let cookieHeader = cookies.headerValue
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        var bodyString: String?
        if let json {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            request.httpBody = data
            bodyString = String(data: data, encoding: .utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let form {
            let body = form.map { "\(Self.percentEncode($0.key))=\(Self.percentEncode($0.value))" }.joined(separator: "&")
            request.httpBody = Data(body.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        } else if let multipart {
            // 与 Ktor 的 MultiPartFormDataContent 一致：表单体不参与 x-zse-96 签名。
            let boundary = "ZhihuPlusPlus-\(UUID().uuidString)"
            var body = ""
            for (name, value) in multipart {
                body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
            }
            body += "--\(boundary)--\r\n"
            request.httpBody = Data(body.utf8)
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        }

        if method != .get, let xsrf = cookies["_xsrf"] {
            request.setValue(xsrf, forHTTPHeaderField: "x-xsrftoken")
        }

        if sign, requestURL.host?.hasSuffix("zhihu.com") == true, let dc0 = cookies["d_c0"] {
            request.setValue(ZhihuSignature.zse93, forHTTPHeaderField: "x-zse-93")
            request.setValue(ZhihuSignature.zse96(url: urlString, dc0: dc0, body: bodyString), forHTTPHeaderField: "x-zse-96")
            request.setValue("fetch", forHTTPHeaderField: "x-requested-with")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ZhihuError(message: "无效的响应")
        }
        storeCookies(from: http, url: requestURL)
        return (data, http)
    }

    /// 发送请求并解析 JSON，非 2xx 时抛出带知乎错误信息的异常。
    func json(
        _ method: HTTPMethod = .get,
        _ url: String,
        include: String? = nil,
        json body: [String: Any]? = nil,
        form: [String: String]? = nil,
        headers: [String: String] = [:],
        sign: Bool = true
    ) async throws -> JSONValue {
        let (data, response) = try await send(method, url, include: include, json: body, form: form, headers: headers, sign: sign)
        let parsed = data.isEmpty ? JSONValue(nil) : ((try? JSONValue.parse(data)) ?? JSONValue(nil))
        guard (200..<300).contains(response.statusCode) else {
            let message = parsed["error"]["message"].nonEmptyString
            if parsed["error"]["code"].int == 40352 {
                let redirect = parsed["error"]["redirect"].nonEmptyString.flatMap(URL.init(string:))
                throw ZhihuError(
                    message: message ?? "系统监测到您的网络环境存在异常，请完成验证",
                    statusCode: response.statusCode,
                    verificationURL: redirect ?? URL(string: "https://www.zhihu.com/account/risk_control/")
                )
            }
            // 40353 等 need_login 错误以 403 返回，按未登录处理，界面会提示去登录。
            if parsed["error"]["need_login"].boolValue {
                throw ZhihuError(message: message ?? "请先登录", statusCode: 401)
            }
            switch response.statusCode {
            case 401:
                throw ZhihuError(message: message ?? "登录已失效，请重新登录", statusCode: 401)
            case 403:
                throw ZhihuError(message: message ?? "请求被拒绝，您可能已被风控，请稍后重试或重新登录", statusCode: 403)
            default:
                throw ZhihuError(message: message ?? "请求失败（HTTP \(response.statusCode)）", statusCode: response.statusCode)
            }
        }
        return parsed
    }

    private func storeCookies(from response: HTTPURLResponse, url: URL) {
        var headerFields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headerFields[key] = value
            }
        }
        let received = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        let zhihuCookies = received.filter { $0.domain.hasSuffix("zhihu.com") }
        guard !zhihuCookies.isEmpty else { return }
        var updates: [String: String] = [:]
        for cookie in zhihuCookies {
            updates[cookie.name] = cookie.value
        }
        cookies.merge(updates)
    }

    /// 未登录时向知乎申请游客 `d_c0`，否则无法计算签名，推荐/热榜等接口会被拒绝。
    func ensureGuestCookies() async {
        guard cookies["d_c0"] == nil else { return }
        _ = try? await send(.get, "https://www.zhihu.com/signin?next=%2F", sign: false)
        _ = try? await send(
            .post,
            "https://www.zhihu.com/udid",
            json: [:],
            headers: ["Origin": "https://www.zhihu.com"],
            sign: false
        )
    }
}
