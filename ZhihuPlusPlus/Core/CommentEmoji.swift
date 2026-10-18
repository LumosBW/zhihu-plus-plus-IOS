import SwiftUI
import UIKit

/// 评论里的 `[赞同]` 等表情占位符替换成图片。
///
/// 图片与映射表来自 Android 仓库 `misc/emojis` 的知乎默认表情存档（与 `EmojiManager` 下载的表情组一致），
/// 随 App 打包，避免每次启动请求表情接口。没有收录的占位符保持原文显示。
@MainActor
enum CommentEmoji {
    private static let mapping: [String: String] = {
        guard let url = Bundle.main.url(forResource: "emoji_mapping", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let mapping = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return mapping
    }()

    private static let placeholder = try! NSRegularExpression(pattern: "\\[[^\\[\\]\\s]{1,8}\\]")
    private static var cache: [String: UIImage] = [:]

    /// `size` 为表情边长（pt），一般略大于所在文字的字号。
    static func text(_ string: String, size: CGFloat) -> Text {
        var result = Text(verbatim: "")
        var last = string.startIndex
        for match in placeholder.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
            guard let range = Range(match.range, in: string),
                  let file = mapping[String(string[range])] else { continue }
            let cacheKey = "\(file)@\(size)"
            let image: UIImage
            if let cached = cache[cacheKey] {
                image = cached
            } else {
                guard let source = UIImage(named: file) else { continue }
                // 原图 132px，直接嵌入 Text 会按原始尺寸撑开行高，需要先缩到文字大小。
                image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
                    source.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
                }
                cache[cacheKey] = image
            }
            result = Text("\(result)\(Text(verbatim: String(string[last..<range.lowerBound])))\(Text(Image(uiImage: image)).baselineOffset(-size * 0.2))")
            last = range.upperBound
        }
        return Text("\(result)\(Text(verbatim: String(string[last...])))")
    }
}
