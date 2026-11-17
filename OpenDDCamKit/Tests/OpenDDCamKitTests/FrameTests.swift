import Foundation
import Testing

@testable import OpenDDCamKit

private func frame(_ type: UInt8, _ payload: [UInt8]) -> Data {
    var d = Data([0x0A, 0x0B, 0x0C, type])
    var len = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
    d.append(contentsOf: payload)
    return d
}

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

@Suite struct FrameParserTests {
    @Test func singleCompleteFrame() {
        var p = FrameParser()
        let payload: [UInt8] = [0, 0, 0, 1, 0x67] + bytes("abc")
        let out = p.feed(frame(0, payload))
        #expect(out == [Frame(type: 0, payload: Data(payload))])
        #expect(p.resyncs == 0)
    }

    @Test func frameSplitAcrossChunks() {
        let data = frame(2, [UInt8](repeating: 0x78, count: 100))
        var p = FrameParser()
        #expect(p.feed(data.prefix(5)).isEmpty)
        #expect(p.feed(data[5..<50]).isEmpty)
        #expect(p.feed(data[50...]).count == 1)
    }

    @Test func twoFramesInOneChunk() {
        var p = FrameParser()
        let out = p.feed(frame(0, bytes("A")) + frame(2, bytes("BB")))
        #expect(out.map(\.type) == [0, 2])
        #expect(out.map(\.payload) == [Data(bytes("A")), Data(bytes("BB"))])
    }

    @Test func garbageBeforeSyncIsSkippedAndCounted() {
        var p = FrameParser()
        let out = p.feed(Data([0xFF, 0x00, 0x0A]) + frame(0, bytes("ok")))
        #expect(out.map(\.payload) == [Data(bytes("ok"))])
        #expect(p.resyncs == 1)
    }

    @Test func zeroLengthFrame() {
        var p = FrameParser()
        #expect(p.feed(frame(0, [])) == [Frame(type: 0, payload: Data())])
    }

    @Test func oversizedLengthTriggersResyncNotHang() {
        var bogus = Data([0x0A, 0x0B, 0x0C, 0x00])
        bogus.append(contentsOf: [0x04, 0x00, 0x00, 0x00])  // 64 MiB
        var p = FrameParser(maxPayload: 8 * 1024 * 1024)
        let out = p.feed(bogus + frame(0, bytes("good")))
        #expect(out.map(\.payload) == [Data(bytes("good"))])
        #expect(p.resyncs >= 1)
    }

    @Test func falseSyncWithPlausibleLengthDoesNotSwallowFrames() {
        var bogus = Data([0x0A, 0x0B, 0x0C, 0x00])
        bogus.append(contentsOf: [0, 0, 0x03, 0xE8])  // 1000
        var p = FrameParser()
        let out = p.feed(bogus + frame(0, bytes("real1")) + frame(2, bytes("real2")))
        #expect(out.map(\.payload) == [Data(bytes("real1")), Data(bytes("real2"))])
        #expect(p.resyncs >= 1)
    }

    @Test func headerSplitRightAfterSync() {
        let data = frame(0, bytes("payload"))
        var p = FrameParser()
        #expect(p.feed(data.prefix(3)).isEmpty)
        #expect(p.feed(data.dropFirst(3)).map(\.payload) == [Data(bytes("payload"))])
    }

    @Test func syncMarkerSplitAcrossFeeds() {
        let data = frame(0, bytes("zz"))
        var p = FrameParser()
        #expect(p.feed(Data(bytes("junk")) + data.prefix(2)).isEmpty)
        #expect(p.feed(data.dropFirst(2)).map(\.payload) == [Data(bytes("zz"))])
    }

    @Test func resyncsCountRegionsNotChunks() {
        var p = FrameParser()
        for _ in 0..<5 { _ = p.feed(Data(repeating: 0x01, count: 100)) }
        _ = p.feed(frame(0, bytes("a")))
        #expect(p.resyncs == 1)
    }

    @Test func noSyncKeepsOnlyTail() {
        var p = FrameParser()
        #expect(p.feed(Data(repeating: 0x01, count: 1000)).isEmpty)
        #expect(p.bufferedByteCount < 3)
    }

    @Test func byteAtATimeDelivery() {
        let stream = frame(0, bytes("one")) + frame(2, bytes("two")) + frame(2, [])
        var p = FrameParser()
        var out: [Frame] = []
        for b in stream { out += p.feed(Data([b])) }
        #expect(out.map(\.type) == [0, 2, 2])
        #expect(p.resyncs == 0)
    }

    @Test func frameFlags() {
        #expect(Frame(type: 0, payload: Data()).isKeyFrame)
        #expect(Frame(type: 0, payload: Data()).isDroppable == false)
        #expect(Frame(type: 2, payload: Data()).isDroppable)
        #expect(Frame(type: 2, payload: Data()).isKeyFrame == false)
    }
}

@Suite struct NALUnitTests {
    private let h264: [UInt8] =
        [0, 0, 0, 1, 0x67] + bytes("sps") + [0, 0, 0, 1, 0x68] + bytes("pps") + [0, 0, 1, 0x65] + bytes("idr")

    @Test func h264Types() {
        #expect(NALUnits.types(in: Data(h264), hevc: false) == [7, 8, 5])
    }

    @Test func hevcTypes() {
        let payload: [UInt8] =
            [0, 0, 0, 1, 0x40, 0x01] + [0, 0, 0, 1, 0x42, 0x01] + [0, 0, 0, 1, 0x44, 0x01] + [0, 0, 1, 0x26, 0x01]
        #expect(NALUnits.types(in: Data(payload), hevc: true) == [32, 33, 34, 19])
    }

    @Test func notAnnexBIsEmpty() {
        let raw = Data([0, 0, 0x10, 0] + bytes("rawavcc"))
        #expect(NALUnits.types(in: raw, hevc: false).isEmpty)
        #expect(NALUnits.units(in: raw, hevc: false).isEmpty)
        #expect(NALUnits.types(in: Data(), hevc: true).isEmpty)
    }

    @Test func unitsAreSplitWithoutStartCodes() {
        let units = NALUnits.units(in: Data(h264), hevc: false)
        #expect(units.map(\.type) == [7, 8, 5])
        #expect(units[0].data == Data([0x67] + bytes("sps")))
        #expect(units[1].data == Data([0x68] + bytes("pps")))
        #expect(units[2].data == Data([0x65] + bytes("idr")))
    }

    @Test func parameterSetsH264() {
        let ps = NALUnits.parameterSets(in: Data(h264), hevc: false)
        #expect(ps.sps == Data([0x67] + bytes("sps")))
        #expect(ps.pps == Data([0x68] + bytes("pps")))
        #expect(ps.vps == nil)
        #expect(ps.isComplete(hevc: false))
    }

    @Test func parameterSetsHEVC() {
        let payload: [UInt8] =
            [0, 0, 0, 1, 0x40, 0x01, 0xAA] + [0, 0, 0, 1, 0x42, 0x01, 0xBB] + [0, 0, 0, 1, 0x44, 0x01, 0xCC]
            + [0, 0, 1, 0x26, 0x01, 0xDD]
        let ps = NALUnits.parameterSets(in: Data(payload), hevc: true)
        #expect(ps.vps == Data([0x40, 0x01, 0xAA]))
        #expect(ps.sps == Data([0x42, 0x01, 0xBB]))
        #expect(ps.pps == Data([0x44, 0x01, 0xCC]))
        #expect(ps.isComplete(hevc: true))
        #expect(ps.isComplete(hevc: false))
    }

    @Test func incompleteParameterSets() {
        let onlyIdr = Data([0, 0, 1, 0x65] + bytes("idr"))
        let ps = NALUnits.parameterSets(in: onlyIdr, hevc: false)
        #expect(ps.isComplete(hevc: false) == false)
    }

    @Test func keyFrameDetection() {
        #expect(NALUnits.containsKeyFrame(Data(h264), hevc: false))
        #expect(NALUnits.containsKeyFrame(Data([0, 0, 1, 0x41, 0x9A]), hevc: false) == false)  // non-IDR slice
        #expect(NALUnits.containsKeyFrame(Data([0, 0, 1, 0x26, 0x01]), hevc: true))  // IDR_W_RADL
        #expect(NALUnits.containsKeyFrame(Data([0, 0, 1, 0x02, 0x01]), hevc: true) == false)  // TRAIL_R
    }
}
