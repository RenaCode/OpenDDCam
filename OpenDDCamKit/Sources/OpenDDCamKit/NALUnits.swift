import Foundation

public struct NALUnit: Sendable, Equatable {
    public var type: Int
    /// The unit without its start code, header byte(s) included.
    public var data: Data
}

public struct ParameterSets: Sendable, Equatable {
    public var vps: Data?
    public var sps: Data?
    public var pps: Data?

    /// H.264 needs SPS and PPS; H.265 also needs VPS.
    public func isComplete(hevc: Bool) -> Bool {
        sps != nil && pps != nil && (!hevc || vps != nil)
    }
}

/// Annex-B helpers for H.264 and H.265 payloads.
public enum NALUnits {
    private static func units(_ bytes: [UInt8], hevc: Bool) -> [NALUnit] {
        var starts: [(code: Int, body: Int)] = []
        var i = 0
        let n = bytes.count
        while i + 3 <= n {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i, i + 3))
                i += 3
            } else if i + 4 <= n, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                starts.append((i, i + 4))
                i += 4
            } else {
                i += 1
            }
        }
        var result: [NALUnit] = []
        for (k, s) in starts.enumerated() where s.body < n {
            var end = k + 1 < starts.count ? starts[k + 1].code : n
            while end > s.body, bytes[end - 1] == 0 { end -= 1 }  // trailing zero bytes
            let header = bytes[s.body]
            let type = hevc ? Int((header >> 1) & 0x3F) : Int(header & 0x1F)
            result.append(NALUnit(type: type, data: Data(bytes[s.body..<max(end, s.body + 1)])))
        }
        return result
    }

    /// NAL units of an Annex-B payload; empty if it is not Annex-B.
    public static func units(in payload: Data, hevc: Bool) -> [NALUnit] {
        units([UInt8](payload), hevc: hevc)
    }

    /// NAL unit types found in an Annex-B payload.
    public static func types(in payload: Data, hevc: Bool) -> [Int] {
        units(in: payload, hevc: hevc).map(\.type)
    }

    /// First VPS (H.265 only), SPS and PPS in the payload.
    public static func parameterSets(in payload: Data, hevc: Bool) -> ParameterSets {
        var ps = ParameterSets()
        let (v, s, p) = hevc ? (32, 33, 34) : (-1, 7, 8)
        for u in units(in: payload, hevc: hevc) {
            if u.type == v, ps.vps == nil { ps.vps = u.data }
            if u.type == s, ps.sps == nil { ps.sps = u.data }
            if u.type == p, ps.pps == nil { ps.pps = u.data }
        }
        return ps
    }

    /// IDR slice (H.264 type 5) or IRAP picture (H.265 types 16 through 21).
    public static func containsKeyFrame(_ payload: Data, hevc: Bool) -> Bool {
        types(in: payload, hevc: hevc).contains { hevc ? (16...21).contains($0) : $0 == 5 }
    }
}
