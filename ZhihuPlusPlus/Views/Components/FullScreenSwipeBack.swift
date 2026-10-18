import SwiftUI
import UIKit

/// 在屏幕任意位置右滑返回上一级。
///
/// 系统只支持从屏幕左边缘右滑返回；iOS 26 新增的全屏返回手势在回答页又会被正文的 WKWebView 吞掉。
/// 这里给导航控制器加一个全屏横向拖动手势，并复用系统边缘返回手势的 target，跟手动画和取消逻辑与系统一致。
/// 复用 target 依赖 UIKit 的 KVC 键 `targets`（FDFullscreenPopGesture 等库的常用做法），取不到时不安装，退回系统默认行为。
///
/// 顶层页面不安装：顶层的横向滑动交给主界面的 Tab 翻页（见 `MainTabView`）。
struct FullScreenSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Installer { Installer() }

    func updateUIViewController(_ controller: Installer, context: Context) {}

    final class Installer: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if let navigation = navigationController, navigation.view.layoutMargins.left == 0 {
                // 导航栈放进横向翻页 ScrollView 后，导航容器的页边距变成 0，大标题会贴到屏幕最左；
                // 补回系统默认的 16pt（导航栏沿用父视图页边距）。
                navigation.view.preservesSuperviewLayoutMargins = false
                navigation.view.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
                navigation.navigationBar.setNeedsLayout()
            }
            guard let navigation = navigationController,
                  let systemGesture = navigation.interactivePopGestureRecognizer,
                  !(navigation.view.gestureRecognizers ?? []).contains(where: { $0 is FullScreenPopGesture }),
                  let targets = systemGesture.value(forKey: "targets") else { return }
            let gesture = FullScreenPopGesture(navigation: navigation)
            gesture.setValue(targets, forKey: "targets")
            navigation.view.addGestureRecognizer(gesture)
        }
    }
}

private final class FullScreenPopGesture: UIPanGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var navigation: UINavigationController?

    init(navigation: UINavigationController) {
        self.navigation = navigation
        super.init(target: nil, action: nil)
        delegate = self
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigation, navigation.viewControllers.count > 1, navigation.transitionCoordinator == nil else { return false }
        let velocity = velocity(in: view)
        return velocity.x > 0 && velocity.x > abs(velocity.y)
    }

    /// 只能纵向滚动的列表和正文，在横向右滑时让位给返回手势；
    /// 能横向滚动且还没滚到最左边的滚动视图（如话题标签）保持优先，先滚动内容。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let scrollView = otherGestureRecognizer.view as? UIScrollView,
              otherGestureRecognizer == scrollView.panGestureRecognizer else { return false }
        let scrollsHorizontally = scrollView.contentSize.width > scrollView.bounds.width + 1
        return !scrollsHorizontally || scrollView.contentOffset.x <= -scrollView.adjustedContentInset.left
    }
}
