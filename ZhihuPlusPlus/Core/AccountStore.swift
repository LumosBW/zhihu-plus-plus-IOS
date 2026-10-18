import Foundation
import Observation

struct AccountProfile: Codable, Hashable {
    var id: String
    var name: String
    var urlToken: String?
    var headline: String
    var avatarURL: String?

    init(json: JSONValue) {
        id = json["id"].stringValue
        name = json["name"].stringValue
        urlToken = json["url_token"].nonEmptyString
        headline = HTML.plainText(json["headline"].stringValue)
        avatarURL = json["avatar_url"].nonEmptyString
    }
}

/// 账号状态，对应 Android 版 `ZhihuAccountRepository` 的单账号子集。
@MainActor
@Observable
final class AccountStore {
    static let shared = AccountStore()

    private(set) var profile: AccountProfile?
    private let profileKey = "account.profile"

    var isLoggedIn: Bool { profile != nil && ZhihuClient.shared.cookies["z_c0"] != nil }

    private init() {
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let saved = try? JSONDecoder().decode(AccountProfile.self, from: data),
           ZhihuClient.shared.cookies["z_c0"] != nil {
            profile = saved
        }
    }

    /// 用新的 Cookie 登录并通过 `/api/v4/me` 校验，失败时恢复原 Cookie。
    func login(cookies: [String: String]) async throws {
        let client = ZhihuClient.shared
        let previous = client.cookies.all
        client.cookies.replaceAll(cookies)
        do {
            let me = try await client.json(.get, "https://www.zhihu.com/api/v4/me")
            guard me["id"].nonEmptyString != nil else {
                throw ZhihuError(message: "无法获取账号信息")
            }
            setProfile(AccountProfile(json: me))
        } catch {
            client.cookies.replaceAll(previous)
            throw error
        }
    }

    func refreshProfile() async {
        guard ZhihuClient.shared.cookies["z_c0"] != nil else { return }
        if let me = try? await ZhihuClient.shared.json(.get, "https://www.zhihu.com/api/v4/me"),
           me["id"].nonEmptyString != nil {
            setProfile(AccountProfile(json: me))
        }
    }

    func logout() {
        ZhihuClient.shared.cookies.clear()
        setProfile(nil)
    }

    private func setProfile(_ newValue: AccountProfile?) {
        profile = newValue
        if let newValue, let data = try? JSONEncoder().encode(newValue) {
            UserDefaults.standard.set(data, forKey: profileKey)
        } else {
            UserDefaults.standard.removeObject(forKey: profileKey)
        }
    }

    /// 从 `name=value; name2=value2` 形式的字符串解析 Cookie。
    static func parseCookieString(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in text.split(whereSeparator: { $0 == ";" || $0 == "\n" }) {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<separator].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                result[name] = value
            }
        }
        return result
    }
}
