import Photos
import SwiftUI
import UIKit

extension View {
    /// 以官方 App 的方式打开图片：黑色背景淡入、图片从中间放大出现，而不是全屏弹窗默认的自下而上滑入。
    func imageViewer(_ url: Binding<URL?>) -> some View {
        fullScreenCover(item: Binding(get: { url.wrappedValue.map(IdentifiableURL.init) }, set: { url.wrappedValue = $0?.url })) {
            ImageViewer(url: $0.url)
        }
        // 关掉弹窗自带的滑入/滑出动画，由 ImageViewer 自己做淡入淡出。
        .transaction(value: url.wrappedValue) { $0.disablesAnimations = true }
    }
}

/// 全屏图片查看器：单击关闭、双指缩放、双击放大、保存原图（无水印）到相册。
struct ImageViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    @State private var toast: String?
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 1 : 0).ignoresSafeArea()
            Group {
                if let image {
                    ZoomableImageView(image: image, onSingleTap: close).ignoresSafeArea()
                } else if failed {
                    Text("图片加载失败").foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.85)
            VStack {
                HStack {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    if let image {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("图片", image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.headline)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        Button {
                            save(image)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.headline)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding()
                .opacity(shown ? 1 : 0)
                Spacer()
                if let toast {
                    Text(toast)
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 40)
                }
            }
        }
        .presentationBackground(.clear)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { shown = true }
        }
        .task { await load() }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.2)) {
            shown = false
        } completion: {
            dismiss()
        }
    }

    private func load() async {
        do {
            var request = URLRequest(url: url)
            request.setValue("https://www.zhihu.com/", forHTTPHeaderField: "Referer")
            let (data, _) = try await URLSession.shared.data(for: request)
            if let decoded = UIImage(data: data) {
                image = decoded
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }

    private func save(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in show("没有相册写入权限") }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                Task { @MainActor in show(success ? "已保存到相册" : "保存失败") }
            }
        }
    }

    @MainActor
    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            toast = nil
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 5
        scrollView.minimumZoomScale = 1
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            imageView.centerXAnchor.constraint(equalTo: scrollView.contentLayoutGuide.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scrollView.contentLayoutGuide.centerYAnchor),
            scrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: imageView.widthAnchor),
            scrollView.contentLayoutGuide.heightAnchor.constraint(equalTo: imageView.heightAnchor),
        ])
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTapped))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onSingleTap: onSingleTap) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        let onSingleTap: () -> Void

        init(onSingleTap: @escaping () -> Void) {
            self.onSingleTap = onSingleTap
        }

        @objc func singleTapped() {
            onSingleTap()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            scrollView.setZoomScale(scrollView.zoomScale > 1 ? 1 : 2.5, animated: true)
        }
    }
}
