import Foundation

/// One frame of the live stream (TCP 6200 front, 6202 rear).
public struct Frame: Sendable, Equatable {
    public var type: UInt8
    public var payload: Data

    public init(type: UInt8, payload: Data) {
        self.type = type
        self.payload = payload
    }

    /// Type 0 is a key frame.
    public var isKeyFrame: Bool { type == 0 }
    /// Bit 0x02 marks frames that may be dropped under load.
    public var isDroppable: Bool { type & 0x02 != 0 }
}

/// Incremental parser. Each frame is `0A 0B 0C | type | length (4 bytes, big-endian) | payload`.
/// `resyncs` counts regions of bytes that were skipped (garbage or false sync markers),
/// not individual chunks.
public struct FrameParser: Sendable {
    public static let sync: [UInt8] = [0x0A, 0x0B, 0x0C]
    public static let headerLength = 8

    public let maxPayload: Int
    public private(set) var resyncs = 0
    private var buffer: [UInt8] = []
    private var hunting = false

    public init(maxPayload: Int = 8 * 1024 * 1024) {
        self.maxPayload = maxPayload
    }

    public var bufferedByteCount: Int { buffer.count }

    private mutating func skip(_ n: Int) {
        if !hunting {
            resyncs += 1
            hunting = true
        }
        buffer.removeSubrange(0..<n)
    }

    private func findSync(from start: Int) -> Int? {
        let s = Self.sync
        guard buffer.count >= 3, start <= buffer.count - 3 else { return nil }
        var i = start
        while i <= buffer.count - 3 {
            if buffer[i] == s[0], buffer[i + 1] == s[1], buffer[i + 2] == s[2] { return i }
            i += 1
        }
        return nil
    }

    private func length(at pos: Int) -> Int {
        (Int(buffer[pos + 4]) << 24) | (Int(buffer[pos + 5]) << 16) | (Int(buffer[pos + 6]) << 8) | Int(buffer[pos + 7])
    }

    /// True if complete, well-formed frames run from `start` to the end of the buffer
    /// (a trailing partial header is allowed after the first frame).
    private func chainReachesEnd(_ start: Int) -> Bool {
        var pos = start
        var count = 0
        let n = buffer.count
        while pos < n {
            if pos + Self.headerLength > n {
                return count >= 1 && Self.sync.starts(with: buffer[pos..<min(pos + 3, n)])
            }
            guard Array(buffer[pos..<pos + 3]) == Self.sync else { return false }
            let len = length(at: pos)
            if len > maxPayload { return false }
            pos += Self.headerLength + len
            count += 1
        }
        return pos == n && count >= 1
    }

    public mutating func feed(_ data: Data) -> [Frame] {
        buffer.append(contentsOf: data)
        var frames: [Frame] = []
        while true {
            guard let idx = findSync(from: 0) else {
                // Keep only a tail that could start a sync marker split across reads.
                var keep = 0
                var k = min(Self.sync.count - 1, buffer.count)
                while k > 0 {
                    if Self.sync.starts(with: buffer.suffix(k)) {
                        keep = k
                        break
                    }
                    k -= 1
                }
                if buffer.count > keep { skip(buffer.count - keep) }
                return frames
            }
            if idx > 0 { skip(idx) }
            if buffer.count < Self.headerLength { return frames }
            let type = buffer[3]
            let len = length(at: 0)
            if len > maxPayload {
                skip(1)  // false sync: hunt for the next marker
                continue
            }
            let end = Self.headerLength + len
            if buffer.count < end {
                // Waiting for the payload. If a later marker starts a clean run of
                // frames to the end of the buffer, this header was a false sync.
                var resolved = false
                var j = findSync(from: 1)
                while let jj = j, jj < end {
                    if chainReachesEnd(jj) {
                        skip(jj)
                        resolved = true
                        break
                    }
                    j = findSync(from: jj + 1)
                }
                if resolved { continue }
                return frames
            }
            let after = buffer[end..<min(end + 3, buffer.count)]
            if !after.isEmpty, !Self.sync.starts(with: after) {
                skip(1)  // not followed by another marker: false sync
                continue
            }
            frames.append(Frame(type: type, payload: Data(buffer[Self.headerLength..<end])))
            buffer.removeSubrange(0..<end)
            hunting = false
        }
    }
}
