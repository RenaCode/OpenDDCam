import Foundation

/// Minimal JSON tree used for tolerant parsing of camera responses.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses JSON (fragments allowed); nil when the data is not valid JSON.
    public init?(data: Data) {
        guard !data.isEmpty,
            let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        self = JSONValue(any: any)
    }

    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map(JSONValue.init(any:)))
        case let d as [String: Any]:
            self = .object(d.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    /// Integer value; accepts numbers and numeric strings, rejects fractions.
    public var int: Int? {
        switch self {
        case .number(let d): return Self.integral(d)
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            return Double(t).flatMap(Self.integral)
        default: return nil
        }
    }

    private static func integral(_ d: Double) -> Int? {
        guard d.isFinite, d == d.rounded(), abs(d) < 9e18 else { return nil }
        return Int(d)
    }

    /// String value; numbers are rendered, other kinds give nil.
    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let d): return Self.integral(d).map(String.init) ?? String(d)
        default: return nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Object member; nil for non-objects and missing keys.
    public subscript(key: String) -> JSONValue? {
        object?[key]
    }

    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.foundationObject)
        case .object(let o): return o.mapValues(\.foundationObject)
        }
    }

    /// Compact JSON with sorted keys.
    public func encoded() -> Data {
        let obj = foundationObject
        if JSONSerialization.isValidJSONObject(obj),
            let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        {
            return data
        }
        // Top-level fragments (numbers, strings) are not valid objects for JSONSerialization.
        switch self {
        case .string(let s): return (try? JSONSerialization.data(withJSONObject: [s], options: []))
                .map { Data($0.dropFirst().dropLast()) } ?? Data("null".utf8)
        case .number(let d): return Data((Self.integral(d).map(String.init) ?? String(d)).utf8)
        case .bool(let b): return Data((b ? "true" : "false").utf8)
        default: return Data("null".utf8)
        }
    }
}
