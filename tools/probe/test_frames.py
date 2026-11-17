"""Tests for the live-stream frame parser used by the in-car probe.

Frame layout: 3 sync bytes 0A 0B 0C,
1 type byte, 4-byte big-endian payload length, then the payload.
"""

import unittest

from frames import FrameParser, SYNC


def frame(ftype: int, payload: bytes) -> bytes:
    return SYNC + bytes([ftype]) + len(payload).to_bytes(4, "big") + payload


class FrameParserTests(unittest.TestCase):
    def test_single_complete_frame(self):
        p = FrameParser()
        out = p.feed(frame(0, b"\x00\x00\x00\x01\x67abc"))
        self.assertEqual(out, [(0, b"\x00\x00\x00\x01\x67abc")])
        self.assertEqual(p.resyncs, 0)

    def test_frame_split_across_chunks(self):
        data = frame(2, b"x" * 100)
        p = FrameParser()
        self.assertEqual(p.feed(data[:5]), [])
        self.assertEqual(p.feed(data[5:50]), [])
        self.assertEqual(p.feed(data[50:]), [(2, b"x" * 100)])

    def test_two_frames_in_one_chunk(self):
        p = FrameParser()
        out = p.feed(frame(0, b"A") + frame(2, b"BB"))
        self.assertEqual(out, [(0, b"A"), (2, b"BB")])

    def test_garbage_before_sync_is_skipped_and_counted(self):
        p = FrameParser()
        out = p.feed(b"\xff\x00\x0a" + frame(0, b"ok"))
        self.assertEqual(out, [(0, b"ok")])
        self.assertEqual(p.resyncs, 1)

    def test_zero_length_frame(self):
        p = FrameParser()
        self.assertEqual(p.feed(frame(0, b"")), [(0, b"")])

    def test_oversized_length_triggers_resync_not_hang(self):
        # A length above the sanity limit means we locked onto a false sync.
        bogus = SYNC + b"\x00" + (64 * 1024 * 1024).to_bytes(4, "big")
        p = FrameParser(max_payload=8 * 1024 * 1024)
        out = p.feed(bogus + frame(0, b"good"))
        self.assertEqual(out, [(0, b"good")])
        self.assertGreaterEqual(p.resyncs, 1)

    def test_false_sync_with_plausible_length_does_not_swallow_frames(self):
        # A stray 0A 0B 0C with a believable length must not stall the parser
        # once real frames follow; it must resync on the next real marker.
        bogus = SYNC + b"\x00" + (1000).to_bytes(4, "big")
        p = FrameParser()
        out = p.feed(bogus + frame(0, b"real1") + frame(2, b"real2"))
        self.assertEqual(out, [(0, b"real1"), (2, b"real2")])
        self.assertGreaterEqual(p.resyncs, 1)

    def test_header_split_right_after_sync(self):
        data = frame(0, b"payload")
        p = FrameParser()
        self.assertEqual(p.feed(data[:3]), [])
        self.assertEqual(p.feed(data[3:]), [(0, b"payload")])

    def test_sync_marker_split_across_feeds(self):
        data = frame(0, b"zz")
        p = FrameParser()
        self.assertEqual(p.feed(b"junk" + data[:2]), [])
        self.assertEqual(p.feed(data[2:]), [(0, b"zz")])

    def test_resyncs_count_skipped_regions_not_chunks(self):
        p = FrameParser()
        for _ in range(5):
            p.feed(b"\x01" * 100)
        p.feed(frame(0, b"a"))
        self.assertEqual(p.resyncs, 1)

    def test_no_sync_at_all_keeps_tail_only(self):
        p = FrameParser()
        self.assertEqual(p.feed(b"\x01" * 1000), [])
        # Buffer must not grow without bound while hunting for sync.
        self.assertLess(len(p.buffer), len(SYNC))


class AnnexBTests(unittest.TestCase):
    def test_detects_annexb_and_nal_types(self):
        from frames import nal_types

        payload = b"\x00\x00\x00\x01\x67sps\x00\x00\x00\x01\x68pps\x00\x00\x01\x65idr"
        self.assertEqual(nal_types(payload, hevc=False), [7, 8, 5])

    def test_hevc_nal_types(self):
        from frames import nal_types

        # HEVC NAL type = (byte >> 1) & 0x3F; VPS=32, SPS=33, PPS=34, IDR_W_RADL=19
        payload = b"\x00\x00\x00\x01\x40\x01" + b"\x00\x00\x00\x01\x42\x01" + b"\x00\x00\x00\x01\x44\x01" + b"\x00\x00\x01\x26\x01"
        self.assertEqual(nal_types(payload, hevc=True), [32, 33, 34, 19])

    def test_not_annexb_returns_empty(self):
        from frames import nal_types

        self.assertEqual(nal_types(b"\x00\x00\x10\x00rawavcc", hevc=False), [])


if __name__ == "__main__":
    unittest.main()
