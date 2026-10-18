import SwiftUI
import UIKit

/// 让页面底部给键盘让位。
///
/// 主界面把各页的导航栈放在横向分页 ScrollView 里（见 `MainTabView`），ScrollView 不会把键盘安全区传给内容，
/// 评论输入栏这类 `safeAreaInset(edge: .bottom)` 控件因此会被键盘挡住。
/// 这里自己监听键盘位置，把键盘挡住的高度补成底部安全区；外层需配合 `.ignoresSafeArea(.keyboard)`，避免重复让位。
struct KeyboardAvoidance: ViewModifier {
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: height)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { update($0) }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { update($0) }
    }

    private func update(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) else { return }
        let hiding = notification.name == UIResponder.keyboardWillHideNotification
        // 键盘高度里包含 Home 指示条那段，它本来就在底部安全区内，要扣掉。
        let overlap = hiding ? 0 : max(0, window.bounds.maxY - frame.minY - window.safeAreaInsets.bottom)
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        withAnimation(.easeOut(duration: duration)) { height = overlap }
    }
}

extension View {
    func keyboardAvoidance() -> some View {
        modifier(KeyboardAvoidance())
    }
}
