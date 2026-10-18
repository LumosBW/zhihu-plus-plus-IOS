import CryptoKit
import Foundation

/// 知乎 Web 端 `x-zse-96` 签名算法（v4）。
///
/// 移植自 Android 版 `shared/.../util/ZseSigner.kt` 与 `ZhihuFetchSignature.kt`。
enum ZseSigner {
    private static let zk: [UInt32] = [
        1170614578, 1024848638, 1413669199, 3951632832, 3528873006, 2921909214, 4151847688, 3997739139,
        1933479194, 3323781115, 3888513386, 460404854, 3747539722, 2403641034, 2615871395, 2119585428,
        2265697227, 2035090028, 2773447226, 4289380121, 4217216195, 2200601443, 3051914490, 1579901135,
        1321810770, 456816404, 2903323407, 4065664991, 330002838, 3506006750, 363569021, 2347096187,
    ]

    private static let zb: [UInt8] = [
        20, 223, 245, 7, 248, 2, 194, 209, 87, 6, 227, 253, 240, 128, 222, 91, 237, 9, 125, 157, 230,
        93, 252, 205, 90, 79, 144, 199, 159, 197, 186, 167, 39, 37, 156, 198, 38, 42, 43, 168, 217,
        153, 15, 103, 80, 189, 71, 191, 97, 84, 247, 95, 36, 69, 14, 35, 12, 171, 28, 114, 178, 148,
        86, 182, 32, 83, 158, 109, 22, 255, 94, 238, 151, 85, 77, 124, 254, 18, 4, 26, 123, 176, 232,
        193, 131, 172, 143, 142, 150, 30, 10, 146, 162, 62, 224, 218, 196, 229, 1, 192, 213, 27, 110,
        56, 231, 180, 138, 107, 242, 187, 54, 120, 19, 44, 117, 228, 215, 203, 53, 239, 251, 127, 81,
        11, 133, 96, 204, 132, 41, 115, 73, 55, 249, 147, 102, 48, 122, 145, 106, 118, 74, 190, 29, 16,
        174, 5, 177, 129, 63, 113, 99, 31, 161, 76, 246, 34, 211, 13, 60, 68, 207, 160, 65, 111, 82,
        165, 67, 169, 225, 57, 112, 244, 155, 51, 236, 200, 233, 58, 61, 47, 100, 137, 185, 64, 17, 70,
        234, 163, 219, 108, 170, 166, 59, 149, 52, 105, 24, 212, 78, 173, 45, 0, 116, 226, 119, 136,
        206, 135, 175, 195, 25, 92, 121, 208, 126, 139, 3, 75, 141, 21, 130, 98, 241, 40, 154, 66, 184,
        49, 181, 46, 243, 88, 101, 183, 8, 23, 72, 188, 104, 179, 210, 134, 250, 201, 164, 89, 216,
        202, 220, 50, 221, 152, 140, 33, 235, 214,
    ]

    private static let alphabet = Array("6fpLRqJO8M/c3jnYxFkUVC4ZIG12SiH=5v0mXDazWBTsuw7QetbKdoPyAl+hN9rgE")
    private static let key16 = Array("059053f7d15e01d7".utf8)

    @inline(__always)
    private static func rotl(_ value: UInt32, _ shift: UInt32) -> UInt32 {
        (value << shift) | (value >> (32 - shift))
    }

    private static func readBE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func appendBE(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: value >> 24))
        out.append(UInt8(truncatingIfNeeded: value >> 16))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value))
    }

    private static func gTransform(_ tt: UInt32) -> UInt32 {
        let ti = UInt32(zb[Int(tt >> 24 & 0xFF)]) << 24
            | UInt32(zb[Int(tt >> 16 & 0xFF)]) << 16
            | UInt32(zb[Int(tt >> 8 & 0xFF)]) << 8
            | UInt32(zb[Int(tt & 0xFF)])
        return ti ^ rotl(ti, 2) ^ rotl(ti, 10) ^ rotl(ti, 18) ^ rotl(ti, 24)
    }

    private static func rBlock(_ input: [UInt8]) -> [UInt8] {
        var tr = [UInt32](repeating: 0, count: 36)
        for i in 0..<4 {
            tr[i] = readBE(input, i * 4)
        }
        for i in 0..<32 {
            let ta = gTransform(tr[i + 1] ^ tr[i + 2] ^ tr[i + 3] ^ zk[i])
            tr[i + 4] = tr[i] ^ ta
        }
        var out = [UInt8]()
        out.reserveCapacity(16)
        appendBE(tr[35], to: &out)
        appendBE(tr[34], to: &out)
        appendBE(tr[33], to: &out)
        appendBE(tr[32], to: &out)
        return out
    }

    private static func xBlocks(_ data: [UInt8], iv initialIV: [UInt8]) -> [UInt8] {
        var iv = initialIV
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var offset = 0
        while offset < data.count {
            var mixed = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 {
                mixed[i] = data[offset + i] ^ iv[i]
            }
            iv = rBlock(mixed)
            out.append(contentsOf: iv)
            offset += 16
        }
        return out
    }

    private static func customEncode(_ input: [UInt8]) -> String {
        var bytes = input
        let rem = bytes.count % 3
        if rem != 0 {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 3 - rem))
        }
        var out = ""
        out.reserveCapacity(bytes.count / 3 * 4)
        var i = 0
        var p = bytes.count - 1
        func mask() -> UInt32 {
            let m = (UInt32(58) >> UInt32(8 * (i % 4))) & 0xFF
            i += 1
            return m
        }
        while p >= 0 {
            var v: UInt32 = 0
            v |= (UInt32(bytes[p]) ^ mask()) & 0xFF
            v |= ((UInt32(bytes[p - 1]) ^ mask()) & 0xFF) << 8
            v |= ((UInt32(bytes[p - 2]) ^ mask()) & 0xFF) << 16
            out.append(alphabet[Int(v & 63)])
            out.append(alphabet[Int((v >> 6) & 63)])
            out.append(alphabet[Int((v >> 12) & 63)])
            out.append(alphabet[Int((v >> 18) & 63)])
            p -= 3
        }
        return out
    }

    /// `seed` 对应 zse-v4.js 中的随机首字节，服务端不校验其取值；Android 版固定为 210。
    static func encryptZseV4(_ input: String, seed: UInt8 = 210) -> String {
        var plain: [UInt8] = [seed, 0]
        plain.append(contentsOf: Array(input.utf8))
        let pad = 16 - (plain.count % 16)
        plain.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))

        var first = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            first[i] = plain[i] ^ key16[i] ^ 42
        }
        let c0 = rBlock(first)
        var cipher = c0
        if plain.count > 16 {
            cipher.append(contentsOf: xBlocks(Array(plain[16...]), iv: c0))
        }
        return customEncode(cipher)
    }
}

enum ZhihuSignature {
    static let zse93 = "101_3_3.0"

    static func md5Hex(_ input: String) -> String {
        Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 生成 `x-zse-96`。`url` 必须是实际发送的完整 URL 字符串。
    static func zse96(url: String, dc0: String, body: String?) -> String {
        let afterScheme = url.components(separatedBy: "//").dropFirst().joined(separator: "//")
        let pathname: String
        if let slash = afterScheme.firstIndex(of: "/") {
            pathname = String(afterScheme[slash...])
        } else {
            pathname = "/"
        }
        let source = [zse93, pathname, dc0, body].compactMap { $0 }.joined(separator: "+")
        return "2.0_" + ZseSigner.encryptZseV4(md5Hex(source))
    }
}
