import Foundation

/// 轻量 JSON 访问器。
///
/// 知乎接口字段多变且经常缺失，Android 版依赖 kotlinx.serialization 的宽松解码；
/// 这里用 `JSONSerialization` + 可选链访问，避免因为一个字段类型变化导致整页解码失败。
/// 使用 `JSONSerialization` 而不是 `Codable` 的另一个原因是：想法（pin）等 ID 超过 Double 精度，
/// `NSNumber` 能完整保留 Int64。
struct JSONValue: @unchecked Sendable {
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = raw is NSNull ? nil : raw
    }

    static func parse(_ data: Data) throws -> JSONValue {
        JSONValue(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    subscript(key: String) -> JSONValue {
        JSONValue((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSONValue {
        guard let array = raw as? [Any], array.indices.contains(index) else { return JSONValue(nil) }
        return JSONValue(array[index])
    }

    var exists: Bool { raw != nil }

    var string: String? {
        switch raw {
        case let value as String:
            return value
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue ? "true" : "false"
            }
            return value.stringValue
        default:
            return nil
        }
    }

    var stringValue: String { string ?? "" }

    /// 非空字符串，空串视为 nil。
    var nonEmptyString: String? {
        guard let value = string, !value.isEmpty else { return nil }
        return value
    }

    var int: Int? {
        switch raw {
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value)
        default: return nil
        }
    }

    var intValue: Int { int ?? 0 }

    var int64: Int64? {
        switch raw {
        case let value as NSNumber: return value.int64Value
        case let value as String: return Int64(value)
        default: return nil
        }
    }

    var double: Double? {
        switch raw {
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    var bool: Bool? {
        switch raw {
        case let value as NSNumber: return value.boolValue
        case let value as String: return value == "true" || value == "1"
        default: return nil
        }
    }

    var boolValue: Bool { bool ?? false }

    var array: [JSONValue] {
        (raw as? [Any])?.map(JSONValue.init) ?? []
    }

    var object: [String: Any]? { raw as? [String: Any] }

    func has(_ key: String) -> Bool {
        (raw as? [String: Any])?[key] != nil
    }
}
