"""Parser for the camera's raw live-stream framing (TCP 6200 front / 6202 rear).

Each frame: 0A 0B 0C | type (1 byte) | payload length (4 bytes, big-endian) | payload.
Standard library only, so the probe runs on a bare laptop.
"""

from __future__ import annotations

SYNC = b"\x0a\x0b\x0c"
HEADER_LEN = 8


class FrameParser:
    """Incremental parser. `resyncs` counts regions of bytes that had to be
    skipped (garbage or false sync markers), not individual chunks."""

    def __init__(self, max_payload: int = 8 * 1024 * 1024):
        self.buffer = bytearray()
        self.max_payload = max_payload
        self.resyncs = 0
        self._hunting = False

    def _skip(self, n: int) -> None:
        if not self._hunting:
            self.resyncs += 1
            self._hunting = True
        del self.buffer[:n]

    def _chain_reaches_end(self, start: int) -> bool:
        """True if complete, well-formed frames run from `start` to the end of
        the buffer (a trailing partial header is allowed after the first frame)."""
        pos, count, n = start, 0, len(self.buffer)
        while pos < n:
            if pos + HEADER_LEN > n:
                return count >= 1 and SYNC.startswith(bytes(self.buffer[pos : pos + 3]))
            if self.buffer[pos : pos + 3] != SYNC:
                return False
            length = int.from_bytes(self.buffer[pos + 4 : pos + 8], "big")
            if length > self.max_payload:
                return False
            pos += HEADER_LEN + length
            count += 1
        return pos == n and count >= 1

    def feed(self, data: bytes) -> list[tuple[int, bytes]]:
        self.buffer += data
        frames: list[tuple[int, bytes]] = []
        while True:
            idx = self.buffer.find(SYNC)
            if idx < 0:
                # Keep only a tail that could start a sync marker split across reads.
                keep = 0
                for k in range(min(len(SYNC) - 1, len(self.buffer)), 0, -1):
                    if SYNC.startswith(bytes(self.buffer[-k:])):
                        keep = k
                        break
                if len(self.buffer) > keep:
                    self._skip(len(self.buffer) - keep)
                return frames
            if idx > 0:
                self._skip(idx)
            if len(self.buffer) < HEADER_LEN:
                return frames
            ftype = self.buffer[3]
            length = int.from_bytes(self.buffer[4:8], "big")
            if length > self.max_payload:
                self._skip(1)  # false sync: hunt for the next marker
                continue
            end = HEADER_LEN + length
            if len(self.buffer) < end:
                # Waiting for the payload. If a later marker starts a clean run of
                # frames to the end of the buffer, this header was a false sync.
                j = self.buffer.find(SYNC, 1)
                while 0 < j < end:
                    if self._chain_reaches_end(j):
                        self._skip(j)
                        break
                    j = self.buffer.find(SYNC, j + 1)
                else:
                    return frames
                continue
            after = bytes(self.buffer[end : end + len(SYNC)])
            if after and not SYNC.startswith(after):
                # The frame is not followed by another marker: false sync.
                self._skip(1)
                continue
            frames.append((ftype, bytes(self.buffer[HEADER_LEN:end])))
            del self.buffer[:end]
            self._hunting = False


def nal_types(payload: bytes, hevc: bool) -> list[int]:
    """NAL unit types found in an Annex-B payload; [] if it is not Annex-B."""
    types: list[int] = []
    i, n = 0, len(payload)
    while i + 3 <= n:
        if payload[i : i + 3] == b"\x00\x00\x01":
            start = i + 3
        elif payload[i : i + 4] == b"\x00\x00\x00\x01":
            start = i + 4
        else:
            i += 1
            continue
        if start < n:
            b = payload[start]
            types.append((b >> 1) & 0x3F if hevc else b & 0x1F)
        i = start
    return types
