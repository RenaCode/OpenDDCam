import Foundation

// All models are built from tolerant JSON: fields are optional and numbers may be strings.

private func int(_ o: [String: JSONValue], _ k: String) -> Int? { o[k]?.int }
private func str(_ o: [String: JSONValue], _ k: String) -> String? { o[k]?.string }

public struct BaseInfo: Sendable, Equatable {
    public enum CardState: Sendable, Equatable { case missing, needsFormat, ok, unknown }

    public var nickname: String?
    public var model: String?
    public var version: String?
    public var serialNumber: String?
    public var uuid: String?
    /// Raw `default_user`: the phone bound to the camera as main user.
    public var defaultUser: String?
    public var totalRuntime: Int?
    public var needsUpdate: Bool
    /// Capacities in KB.
    public var sdCapacity: Int?
    public var sdSpare: Int?
    public var extSdCapacity: Int?
    public var extSdSpare: Int?
    /// 0 = H.264, 1 = H.265.
    public var previewEncType: Int?
    /// The `*bitrate` fields by their raw key (hbbitrate and so on).
    public var bitrates: [String: Int]

    static let bitrateKeys = [
        "hbbitrate", "hsbitrate", "mbbitrate", "msbitrate", "lbbitrate", "lsbitrate", "rbbitrate", "rsbitrate",
    ]

    public init(_ o: [String: JSONValue]) {
        nickname = str(o, "nickname")
        model = str(o, "model")
        version = str(o, "version")
        serialNumber = str(o, "sn")
        uuid = str(o, "uuid")
        defaultUser = str(o, "default_user")
        totalRuntime = int(o, "totalruntime")
        needsUpdate = (int(o, "is_neeed_update") ?? 0) != 0
        sdCapacity = int(o, "sdcapacity")
        sdSpare = int(o, "sdspare")
        extSdCapacity = int(o, "ext_sdcapacity")
        extSdSpare = int(o, "ext_sdspare")
        previewEncType = int(o, "preview_enc_type")
        bitrates = Dictionary(uniqueKeysWithValues: Self.bitrateKeys.compactMap { k in int(o, k).map { (k, $0) } })
    }

    public var isHEVC: Bool { previewEncType == 1 }

    public var cardState: CardState {
        guard let c = sdCapacity else { return .unknown }
        if c == 0 { return .missing }
        if c < 0 { return .needsFormat }
        return .ok
    }

    /// Empty or the text "null" means nobody is bound as main user.
    public var hasMainUser: Bool {
        guard let u = defaultUser?.trimmingCharacters(in: .whitespaces) else { return false }
        return !u.isEmpty && u != "null"
    }

    public func isMainUser(uid: String) -> Bool { hasMainUser && defaultUser == uid }
}

public struct StorageInfo: Sendable, Equatable {
    public var sdCapacity: Int?
    public var sdSpare: Int?
    public var extSdCapacity: Int?
    public var extSdSpare: Int?
    public var normalRecordings: Int?
    public var eventRecordings: Int?
    public var cycleRecordSpace: Int?
    public var isSmartCard: Bool

    public init(_ o: [String: JSONValue]) {
        sdCapacity = int(o, "sdcapacity")
        sdSpare = int(o, "sdspare")
        extSdCapacity = int(o, "ext_sdcapacity")
        extSdSpare = int(o, "ext_sdspare")
        normalRecordings = int(o, "n_num")
        eventRecordings = int(o, "g_num")
        cycleRecordSpace = int(o, "cycle_record_space")
        isSmartCard = int(o, "smart_ok") == 1
    }
}

public struct RecordingFile: Sendable, Equatable {
    public var name: String
    /// Unix seconds.
    public var startTime: Int?
    public var endTime: Int?
    public var size: Int?
    public var matchValue: Int?
    /// `matchval` of "ALL": a small `_S` stream exists as well.
    public var hasSmallStream: Bool

    init?(_ v: JSONValue) {
        guard let o = v.object, let name = str(o, "name"), !name.isEmpty else { return nil }
        self.name = name
        startTime = int(o, "starttime")
        endTime = int(o, "endtime")
        size = int(o, "size")
        matchValue = int(o, "matchval")
        hasSmallStream = o["matchval"]?.string?.uppercased() == "ALL"
    }
}

public struct PlaybackList: Sendable, Equatable {
    /// The camera's own `num`.
    public var count: Int?
    public var files: [RecordingFile]

    public init(_ o: [String: JSONValue]) {
        count = int(o, "num")
        files = (o["file"]?.array ?? []).compactMap(RecordingFile.init)
    }
}

public struct EventVideo: Sendable, Equatable {
    public var name: String
    public var start: Int?
    public var end: Int?
    public var size: Int?
}

public struct EventEntry: Sendable, Equatable {
    public var imageName: String?
    public var imageSize: Int?
    public var smallVideo: EventVideo?
    public var bigVideo: EventVideo?

    init(_ o: [String: JSONValue]) {
        imageName = str(o, "imgname").flatMap { $0.isEmpty ? nil : $0 }
        imageSize = int(o, "imgsize")
        smallVideo = Self.video(o, "s")
        bigVideo = Self.video(o, "b")
    }

    private static func video(_ o: [String: JSONValue], _ p: String) -> EventVideo? {
        guard let name = str(o, p + "videoname"), !name.isEmpty else { return nil }
        return EventVideo(
            name: name, start: int(o, p + "starttime"), end: int(o, p + "endtime"), size: int(o, p + "videosize"))
    }

    public static func list(_ o: [String: JSONValue]) -> [EventEntry] {
        (o["event"]?.array ?? []).compactMap { $0.object.map(EventEntry.init) }
    }
}

public enum LockedFiles {
    public static func names(_ o: [String: JSONValue]) -> [String] {
        (o["file"]?.array ?? []).compactMap { str($0.object ?? [:], "filename") }.filter { !$0.isEmpty }
    }
}

public struct GeneralQueryResult: Sendable, Equatable {
    public private(set) var ints: [String: Int] = [:]
    public private(set) var strings: [String: String] = [:]

    public init(_ o: [String: JSONValue]) {
        for item in o["int_params"]?.array ?? [] {
            if let k = item["key"]?.string, let v = item["value"]?.int { ints[k] = v }
        }
        for item in o["string_params"]?.array ?? [] {
            if let k = item["key"]?.string, let v = item["value"]?.string { strings[k] = v }
        }
    }

    public func int(_ key: String) -> Int? { ints[key] ?? strings[key].flatMap { JSONValue.string($0).int } }
    public func string(_ key: String) -> String? { strings[key] }
}

public struct MailboxMessage: Sendable, Equatable {
    public var msgid: String
    /// `data` as an object; the camera sends it as an object or as a string with JSON.
    public var data: [String: JSONValue]

    public static func list(_ o: [String: JSONValue]) -> [MailboxMessage] {
        (o["msg"]?.array ?? []).compactMap { item in
            guard let m = item.object, let id = str(m, "msgid"), !id.isEmpty else { return nil }
            var data: [String: JSONValue] = [:]
            switch m["data"] {
            case .object(let d)?: data = d
            case .string(let s)?: data = JSONValue(data: Data(s.utf8))?.object ?? [:]
            default: break
            }
            return MailboxMessage(msgid: id, data: data)
        }
    }
}
