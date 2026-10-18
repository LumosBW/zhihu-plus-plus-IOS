import SwiftUI

/// 全局视觉规范：知乎蓝主色、页面底色 / 卡片色、字号与间距。列表页、正文页、底栏统一使用这里的定义。
enum Theme {
    /// 知乎蓝 #056DE8（深色模式 #428EFF），与 Assets 中的 AccentColor 一致。
    static let brand = Color.accentColor
    /// 页面底色：浅色模式为浅灰，深色模式为纯黑。
    static let background = Color(.systemGroupedBackground)
    /// 卡片色：浅色模式为白色，深色模式为深灰。
    static let card = Color(.secondarySystemGroupedBackground)
    static let cardRadius: CGFloat = 12
    static let imageRadius: CGFloat = 8
    /// 页面左右边距与卡片内边距。
    static let pagePadding: CGFloat = 12
    static let cardPadding: CGFloat = 14
    /// 次要文字仍保持足够的明暗对比，避免小字号在卡片上过淡。
    static let secondaryText = Color.primary.opacity(0.72)
    static let metaText = Color.primary.opacity(0.6)

    enum Font {
        static let cardTitle = SwiftUI.Font.headline
        static let body = SwiftUI.Font.subheadline
        static let excerpt = SwiftUI.Font.subheadline
        static let author = SwiftUI.Font.footnote.weight(.medium)
        static let meta = SwiftUI.Font.caption
    }

    /// 热榜前三名的渐变色。
    static func rankGradient(_ rank: Int) -> LinearGradient {
        let colors: [Color]
        switch rank {
        case 1: colors = [Color(red: 1, green: 0.27, blue: 0.23), Color(red: 1, green: 0.55, blue: 0.2)]
        case 2: colors = [Color(red: 1, green: 0.45, blue: 0.15), Color(red: 1, green: 0.7, blue: 0.2)]
        case 3: colors = [Color(red: 1, green: 0.66, blue: 0.1), Color(red: 1, green: 0.82, blue: 0.3)]
        default: colors = [.secondary, .secondary]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    /// 把 List 的一行变成悬浮在灰色底上的白色圆角卡片。
    func feedCard() -> some View {
        self
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .listRowInsets(EdgeInsets(top: 5, leading: Theme.pagePadding, bottom: 5, trailing: Theme.pagePadding))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// 卡片列表页的底色：隐藏 List 默认背景，换成灰色页面底色。
    func cardListStyle() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
    }

    /// 不加卡片、只去掉分隔线和背景的行（加载更多、分段选择器等）。
    func plainCardRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 5, leading: Theme.pagePadding, bottom: 5, trailing: Theme.pagePadding))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
