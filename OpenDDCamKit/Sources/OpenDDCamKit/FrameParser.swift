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
///
/// Work is linear in the input: consumed bytes are dropped by moving a read offset (the
/// storage is compacted occasionally), and while a long payload is incomplete only the
/// newly arrived bytes are searched for a later sync marker.
public struct FrameParser: Sendable {
    public static let sync: [UInt8] = [0x0A, 0x0B, 0x0C]
    public static let headerLength = 8

    public let maxPayload: Int
    public private(set) var resyncs = 0
    private var storage: [UInt8] = []
    private var head = 0
    private var hunting = false
    /// Offsets (relative to `head`) of sync markers found at offset >= 1 while waiting.
    private var candidates: [Int] = []
    /// Offsets in [1, scanned) have been searched for sync markers.
    private var scanned = 0

    public init(maxPayload: Int = 8 * 1024 * 1024) {
        self.maxPayload = maxPayload
    }

    public var bufferedByteCount: Int { storage.count - head }

    private var count: Int { storage.count - head }

    private subscript(i: Int) -> UInt8 { storage[head + i] }

    private mutating func advance(_ n: Int) {
        head += n
        scanned = max(0, scanned - n)
        if !candidates.isEmpty {
            candidates = candidates.compactMap { $0 - n >= 1 ? $0 - n : nil }
        }
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64 * 1024 && head * 2 >= storage.count {
            storage.removeSubrange(0..<head)
            head = 0
        }
    }

    private mutating func skip(_ n: Int) {
        if !hunting {
            resyncs += 1
            hunting = true
        }
        advance(n)
    }

    private func findSync(from start: Int) -> Int? {
        let n = count
        guard n >= 3, start <= n - 3 else { return nil }
        return storage.withUnsafeBufferPointer { p -> Int? in
            var i = head + start
            let last = head + n - 3
            while i <= last {
                if p[i] == 0x0A, p[i + 1] == 0x0B, p[i + 2] == 0x0C { return i - head }
                i += 1
            }
            return nil
        }
    }

    private func length(at pos: Int) -> Int {
        (Int(self[pos + 4]) << 24) | (Int(self[pos + 5]) << 16) | (Int(self[pos + 6]) << 8) | Int(self[pos + 7])
    }

    private func isSyncPrefix(_ from: Int, _ to: Int) -> Bool {
        var k = 0
        for i in from..<to {
            if self[i] != Self.sync[k] { return false }
            k += 1
        }
        return true
    }

    /// True if complete, well-formed frames run from `start` to the end of the buffer
    /// (a trailing partial header is allowed after the first frame).
    private func chainReachesEnd(_ start: Int) -> Bool {
        var pos = start
        var frames = 0
        let n = count
        while pos < n {
            if pos + Self.headerLength > n {
                return frames >= 1 && isSyncPrefix(pos, min(pos + 3, n))
            }
            guard self[pos] == 0x0A, self[pos + 1] == 0x0B, self[pos + 2] == 0x0C else { return false }
            let len = length(at: pos)
            if len > maxPayload { return false }
            pos += Self.headerLength + len
            frames += 1
        }
        return pos == n && frames >= 1
    }

    /// Records sync markers at offset >= 1 in bytes that arrived since the last call.
    private mutating func scanForCandidates() {
        let n = count
        var i = max(1, scanned - 2)  // re-check the last two bytes: a marker may straddle reads
        while i <= n - 3 {
            if self[i] == 0x0A, self[i + 1] == 0x0B, self[i + 2] == 0x0C, (candidates.last ?? 0) < i {
                candidates.append(i)
            }
            i += 1
        }
        scanned = max(scanned, n)
    }

    public mutating func feed(_ data: Data) -> [Frame] {
        storage.append(contentsOf: data)
        var frames: [Frame] = []
        while true {
            guard let idx = findSync(from: 0) else {
                // Keep only a tail that could start a sync marker split across reads.
                var keep = 0
                var k = min(Self.sync.count - 1, count)
                while k > 0 {
                    if isSyncPrefixSuffix(k) {
                        keep = k
                        break
                    }
                    k -= 1
                }
                if count > keep { skip(count - keep) }
                return frames
            }
            if idx > 0 { skip(idx) }
            if count < Self.headerLength { return frames }
            let type = self[3]
            let len = length(at: 0)
            if len > maxPayload {
                skip(1)  // false sync: hunt for the next marker
                continue
            }
            let end = Self.headerLength + len
            if count < end {
                // Waiting for the payload. If a later marker starts a clean run of
                // frames to the end of the buffer, this header was a false sync.
                scanForCandidates()
                var resolvedAt: Int?
                for j in candidates where j < end {
                    if chainReachesEnd(j) {
                        resolvedAt = j
                        break
                    }
                }
                if let j = resolvedAt {
                    skip(j)
                    continue
                }
                return frames
            }
            if end < count {
                let tailEnd = min(end + 3, count)
                if !isSyncPrefix(end, tailEnd) {
                    skip(1)  // not followed by another marker: false sync
                    continue
                }
            }
            frames.append(Frame(type: type, payload: Data(storage[(head + Self.headerLength)..<(head + end)])))
            advance(end)
            hunting = false
        }
    }

    /// True if the last `k` buffered bytes are the first `k` bytes of the sync marker.
    private func isSyncPrefixSuffix(_ k: Int) -> Bool {
        isSyncPrefix(count - k, count)
    }
}
