import SwiftUI

@main
struct ZhihuPlusPlusApp: App {
    @State private var account = AccountStore.shared
    @State private var settings = AppSettings.shared

    init() {
        // 图片较多，放大 URLCache 让 AsyncImage 复用缓存。
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(account)
                .environment(settings)
                .task {
                    await ZhihuClient.shared.ensureGuestCookies()
                    await account.refreshProfile()
                }
        }
    }
}
