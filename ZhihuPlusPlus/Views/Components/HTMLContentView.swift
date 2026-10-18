import SwiftUI
import WebKit

/// 用 WKWebView 渲染知乎正文 HTML。
///
/// 处理了知乎正文中的懒加载图片（data-actualsrc / data-original）、公式图片的深色模式，
/// 并把站内链接与图片点击交给原生层处理。
///
/// 支持多段连续内容（回答页往下滑接着看下一个回答）：`sections[0]` 构成初始页面，
/// 新回答追加到末尾；互动状态只更新对应控件，保持正文和阅读位置。
struct HTMLContentView: UIViewRepresentable {
    let sections: [String]
    var fontSize: Double = 17
    var extraCSS: String = ""
    var footerHTML: String = ""
    var onLink: (URL) -> Void = { _ in }
    var onImage: (URL) -> Void = { _ in }
    /// 滚动到距离末尾不足 0.75 屏时触发（最多每秒一次），用于预加载下一段。
    var onNearEnd: () -> Void = {}
    /// action 和回答 ID 同时传给原生层，避免操作错回答。
    var onReaderAction: (String, String) -> Void = { _, _ in }
    /// 屏幕上方 35% 位置所在的段落序号变化时触发（连续阅读时用于记录读到了哪个回答）。
    var onVisibleSection: (Int) -> Void = { _ in }

    init(
        sections: [String],
        fontSize: Double = 17,
        extraCSS: String = "",
        footerHTML: String = "",
        onLink: @escaping (URL) -> Void = { _ in },
        onImage: @escaping (URL) -> Void = { _ in },
        onNearEnd: @escaping () -> Void = {},
        onReaderAction: @escaping (String, String) -> Void = { _, _ in },
        onVisibleSection: @escaping (Int) -> Void = { _ in }
    ) {
        self.sections = sections
        self.fontSize = fontSize
        self.extraCSS = extraCSS
        self.footerHTML = footerHTML
        self.onLink = onLink
        self.onImage = onImage
        self.onNearEnd = onNearEnd
        self.onReaderAction = onReaderAction
        self.onVisibleSection = onVisibleSection
    }

    init(
        html: String,
        fontSize: Double = 17,
        extraCSS: String = "",
        onLink: @escaping (URL) -> Void = { _ in },
        onImage: @escaping (URL) -> Void = { _ in }
    ) {
        self.init(sections: [html], fontSize: fontSize, extraCSS: extraCSS, onLink: onLink, onImage: onImage)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(WeakScriptHandler(context.coordinator), name: "zpp")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.dataDetectorTypes = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsLinkPreview = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let document = Self.document(body: "", fontSize: fontSize, extraCSS: extraCSS)
        if coordinator.loadedDocument != document {
            coordinator.loadedDocument = document
            coordinator.loadedSections = []
            coordinator.loadedFooter = nil
            coordinator.pageReady = false
            webView.loadHTMLString(document, baseURL: URL(string: "https://www.zhihu.com/"))
        }
        coordinator.syncContent()
    }

    static func document(body: String, fontSize: Double, extraCSS: String) -> String {
        """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5">
        <style>
        :root { color-scheme: light dark; }
        body { font-family: -apple-system, "PingFang SC", sans-serif; font-size: \(Int(fontSize))px; line-height: 1.75;
               margin: 0; padding: 16px 16px 48px; color: #1a1a1a; background: transparent;
               word-wrap: break-word; -webkit-text-size-adjust: none; }
        p { margin: 0 0 1em; }
        a { color: #175199; text-decoration: none; }
        img { max-width: 100%; height: auto; border-radius: 4px; display: block; margin: 0 auto; }
        img[eeimg], img.formula { display: inline; vertical-align: middle; border-radius: 0; margin: 0; }
        figure { margin: 1em 0; }
        figcaption { text-align: center; color: #8a8a8a; font-size: .85em; margin-top: 6px; }
        blockquote { margin: 1em 0; padding: 0 12px; border-left: 3px solid #d9d9d9; color: #646464; }
        pre { overflow-x: auto; padding: 12px; background: #f6f6f6; border-radius: 6px; font-size: .85em; line-height: 1.5; }
        code { font-family: Menlo, monospace; font-size: .9em; }
        table { display: block; overflow-x: auto; border-collapse: collapse; }
        td, th { border: 1px solid #d0d0d0; padding: 4px 8px; }
        hr { border: none; border-top: 1px solid #e5e5e5; margin: 1.5em 0; }
        h1 { font-size: 1.35em; line-height: 1.4; margin: 0 0 .6em; }
        h2 { font-size: 1.2em; } h3 { font-size: 1.1em; }
        noscript { display: none; }
        .zpp-title { margin-bottom: .3em; }
        .zpp-title a { color: inherit; }
        .zpp-question-entry { display: block; color: #8a8a8a; font-size: .8em; margin: 0 0 1.2em; }
        .zpp-author { display: flex; align-items: center; gap: 10px; margin: 0 0 1.2em; text-decoration: none; color: inherit; }
        .zpp-author img { width: 38px; height: 38px; border-radius: 50%; margin: 0; }
        .zpp-author .name { font-weight: 600; font-size: .95em; line-height: 1.3; }
        .zpp-author .headline { color: #8a8a8a; font-size: .8em; line-height: 1.3; }
        .zpp-meta { color: #8a8a8a; font-size: .8em; margin-top: 2em; }
        .zpp-cover { width: 100%; border-radius: 8px; margin-bottom: 1em; }
        button { touch-action: manipulation; }
        #zpp-reader-footer:empty { display: none; }
        @media (prefers-color-scheme: dark) {
          body { color: #e3e3e3; }
          a { color: #6aa6ff; }
          img[eeimg], img.formula { filter: invert(.9); }
          blockquote { border-color: #444; color: #a0a0a0; }
          pre { background: #1f1f1f; }
          hr { border-color: #333; }
          td, th { border-color: #444; }
        }
        \(extraCSS)
        </style></head>
        <body><main id="zpp-content">\(body)</main><footer id="zpp-reader-footer"></footer>
        <script>
        (function () {
          function post(message) { window.webkit.messageHandlers.zpp.postMessage(message); }
          function fixImages(root) {
            root.querySelectorAll('img').forEach(function (img) {
              var lazy = img.getAttribute('data-actualsrc') || img.getAttribute('data-original');
              var src = img.getAttribute('src') || '';
              if (lazy && (src === '' || src.indexOf('data:') === 0)) { img.setAttribute('src', lazy); }
            });
          }
          // 用事件委托处理图片点击，后追加的段落也能生效。
          document.addEventListener('click', function (event) {
            var action = event.target.closest && event.target.closest('button[data-reader-action]');
            if (action) {
              event.preventDefault();
              if (!action.disabled) { post({ type: 'readerAction', action: action.dataset.readerAction, id: action.dataset.answerId || '' }); }
              return;
            }
            var img = event.target.closest && event.target.closest('img');
            if (!img || img.hasAttribute('eeimg') || img.closest('a')) { return; }
            post({ type: 'image', url: img.getAttribute('data-original') || img.getAttribute('data-actualsrc') || img.src });
          });
          var lastNearEnd = 0;
          var visibleSection = -1;
          function check() {
            var sections = document.querySelectorAll('.zpp-section');
            if (!sections.length) { return; }
            var index = 0;
            for (var i = 0; i < sections.length; i++) {
              if (sections[i].getBoundingClientRect().top <= window.innerHeight * 0.35) { index = i; }
            }
            if (index !== visibleSection) { visibleSection = index; post({ type: 'visible', index: index }); }
            var height = document.documentElement.scrollHeight;
            if (window.scrollY + window.innerHeight > height - window.innerHeight * 2.5 && Date.now() - lastNearEnd > 400) {
              lastNearEnd = Date.now();
              post({ type: 'nearEnd' });
            }
          }
          window.zppSetSection = function (index, html) {
            var container = document.getElementById('zpp-content');
            var section = container.children[index];
            if (!section) {
              section = document.createElement('section');
              section.className = 'zpp-section';
              container.appendChild(section);
              section.innerHTML = html;
              // 新回答接上后立即再判断一次：回答很短、页面仍接近底部时马上要下一条，不受节流限制。
              lastNearEnd = 0;
              setTimeout(check, 0);
            } else {
              var template = document.createElement('div');
              template.innerHTML = html;
              var body = section.querySelector('.zpp-answer-body');
              var nextBody = template.querySelector('.zpp-answer-body');
              if (body && nextBody && section.zppBodyHTML === nextBody.innerHTML) {
                // 点赞、收藏和关注只替换控件；正文图片、选择文本和滚动位置保持不动。
                template.querySelectorAll('[data-zpp-update]').forEach(function (next) {
                  var current = section.querySelector('[data-zpp-update="' + next.dataset.zppUpdate + '"]');
                  if (current && current.outerHTML !== next.outerHTML) { current.replaceWith(next); }
                });
              } else { section.innerHTML = html; section.zppBodyHTML = nextBody ? nextBody.innerHTML : undefined; }
            }
            var rawBody = section.querySelector('.zpp-answer-body');
            if (typeof section.zppBodyHTML === 'undefined' && rawBody) { section.zppBodyHTML = rawBody.innerHTML; }
            fixImages(section);
          };
          window.zppTrimSections = function (count) {
            var container = document.getElementById('zpp-content');
            while (container.children.length > count) { container.lastElementChild.remove(); }
          };
          window.zppSetFooter = function (html) {
            document.getElementById('zpp-reader-footer').innerHTML = html;
          };
          fixImages(document);
          // 惯性滚动、到底回弹时最后一次 scroll 事件可能收不到，停下后再补算一次，并定时兜底。
          var settle = 0;
          window.addEventListener('scroll', function () {
            check();
            clearTimeout(settle);
            settle = setTimeout(check, 150);
          }, { passive: true });
          setInterval(check, 800);
          check();
        })();
        </script>
        </body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: HTMLContentView
        var loadedDocument: String?
        weak var webView: WKWebView?
        var loadedSections: [String] = []
        var loadedFooter: String?
        var pageReady = false

        init(parent: HTMLContentView) { self.parent = parent }

        func syncContent() {
            guard pageReady, let webView else { return }
            for (index, html) in parent.sections.enumerated() {
                guard index >= loadedSections.count || loadedSections[index] != html,
                      let data = try? JSONEncoder().encode(html),
                      let literal = String(data: data, encoding: .utf8) else { continue }
                webView.evaluateJavaScript("zppSetSection(\(index), \(literal))")
            }
            if loadedSections.count > parent.sections.count {
                webView.evaluateJavaScript("zppTrimSections(\(parent.sections.count))")
            }
            loadedSections = parent.sections
            if loadedFooter != parent.footerHTML,
               let data = try? JSONEncoder().encode(parent.footerHTML),
               let literal = String(data: data, encoding: .utf8) {
                loadedFooter = parent.footerHTML
                webView.evaluateJavaScript("zppSetFooter(\(literal))")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            syncContent()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated || url.scheme == LinkResolver.internalScheme {
                decisionHandler(.cancel)
                parent.onLink(url)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["type"] as? String {
            case "image":
                if let string = body["url"] as? String, let url = URL(string: string) {
                    parent.onImage(url)
                }
            case "nearEnd":
                parent.onNearEnd()
            case "visible":
                if let index = body["index"] as? Int { parent.onVisibleSection(index) }
            case "readerAction":
                if let action = body["action"] as? String { parent.onReaderAction(action, body["id"] as? String ?? "") }
            default:
                break
            }
        }
    }
}

/// 避免 WKUserContentController 强引用 Coordinator 造成循环引用。
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
