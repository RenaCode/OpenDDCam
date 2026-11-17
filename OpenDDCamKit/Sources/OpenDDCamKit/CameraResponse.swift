import Foundation

/// Tolerant view of one camera reply. Parsing never throws or crashes.
public struct CameraResponse: Sendable, Equatable {
    public let rawText: String
    /// Parsed document; a `data` string that holds JSON is replaced by its parsed value.
    public let root: JSONValue?
    public let errcode: Int?
    public let dataWasString: Bool
    public let isJSON: Bool

    /// The reply's content: `data` when it is an object, else the whole root object, else empty.
    public var payload: [String: JSONValue] {
        if let d = root?["data"]?.object { return d }
        return root?.object ?? [:]
    }

    public static func parse(_ raw: Data) -> CameraResponse {
        let text = String(decoding: raw, as: UTF8.self)
        guard var root = JSONValue(data: raw) else {
            return CameraResponse(rawText: text, root: nil, errcode: nil, dataWasString: false, isJSON: false)
        }
        var wasString = false
        if case .object(var obj) = root, case .string(let s)? = obj["data"], !s.isEmpty,
            let inner = JSONValue(data: Data(s.utf8)), inner.object != nil || inner.array != nil
        {
            obj["data"] = inner
            root = .object(obj)
            wasString = true
        }
        return CameraResponse(
            rawText: text, root: root, errcode: root["errcode"]?.int, dataWasString: wasString, isJSON: true)
    }
}
