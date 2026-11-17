#!/usr/bin/env python3
"""OpenDDCam in-car probe: records how a DDPai-based dashcam (e.g. the Volvo
accessory DVR) answers, so the iOS client can be built on real responses.

What it sends:
  * queries only (API_Get*, *ListReq, API_GeneralQuery, API_PlayModeQuery ...);
  * a normal login, like the stock app: API_RequestSessionID, API_RequestCertificate
    (vendor default admin/admin) and API_Logout at the end. The camera may keep a
    login-history entry for this laptop; a fixed per-laptop id limits it to one;
  * API_GetMailboxData (the stock app's keep-alive; it may consume queued events);
  * APP_PlaybackLiveSwitch {"switch":"live"} ONLY if the camera reports another
    mode; "live" is the camera's normal state and the stock app sends the same.
It never sends API_GeneralSave, API_SyncDate, API_MmcFormat, API_SetLockFile,
API_RecordOpt, API_Reboot or anything that changes settings, clock, locks or card.

Usage (laptop joined to the camera's Wi-Fi), Python 3.9+ standard library only:
    python3 ddcam_probe.py                  # results in ~/openddcam-probe/<timestamp>/
The output contains personal data (serial number, login history with phone names,
recording dates and times, possibly GPS). Never publish it unscrubbed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from frames import FrameParser, nal_types
from netcheck import same_subnet, source_address_for
from responses import data_dict, file_names, parse_response, play_mode

MAX_BODY = 2 * 1024 * 1024  # bytes read from any command response
SETTINGS_KEYS = [
    "image_quality", "record_resolution", "tar_download_mode", "video_codec", "mic_switch",
    "wdr_enable", "event_before_time", "event_after_time", "display_mode", "gsensor_mode",
    "gsensor_mode_5level", "gsensor_mode_parking", "gsensor_mode_parking_5level",
    "discontinuous_gsensor_mode", "parking_mode_switch", "parking_power_mgr",
    "delay_poweroff_time", "power_guard_value", "record_split_time", "osd_switch",
    "osd_speedswitch", "osd_speedUnit", "start_sound_switch", "speaker_turn",
    "vertical_mirror", "horizontal_mirror", "scam_vertical_mirror", "scam_horizontal_mirror",
    "ldc_switch", "anti_fog", "timelapse_rec_switch", "quick_report", "rear_warning_switch",
    "record_status", "continuous_recording", "ifcan_set_eventTime", "system_run_time",
    "default_user", "wifi_location", "wifi_relationship",
]


def read_capped(resp, limit: int = MAX_BODY, deadline: float = 15.0) -> bytes:
    """Read a response body with a size cap and an overall deadline."""
    chunks, total, end = [], 0, time.monotonic() + deadline
    while total < limit and time.monotonic() < end:
        chunk = resp.read(min(65536, limit - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks)


def stable_uid() -> str:
    """One id per laptop, so repeated runs do not add new clients on the camera."""
    path = os.path.expanduser("~/.openddcam-probe-uid")
    try:
        with open(path, encoding="utf-8") as f:
            uid = f.read().strip()
            if uid:
                return uid
    except OSError:
        pass
    uid = "openddcam-probe-" + uuid.uuid4().hex[:12]
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(uid)
    except OSError:
        pass
    return uid


def inside_git_worktree(path: str) -> bool:
    p = os.path.abspath(path)
    while True:
        if os.path.exists(os.path.join(p, ".git")):
            return True
        parent = os.path.dirname(p)
        if parent == p:
            return False
        p = parent


class Probe:
    def __init__(self, ip: str, out: str, http_port: int = 80):
        self.ip = ip
        self.http = ip if http_port == 80 else f"{ip}:{http_port}"
        self.out = out
        self.session = ""
        self.seq = 0
        self.summary: list[str] = []
        os.makedirs(out, exist_ok=True)

    def log(self, line: str) -> None:
        print(line, flush=True)
        self.summary.append(line)

    def save(self, name: str, record: dict) -> None:
        self.seq += 1
        path = os.path.join(self.out, f"{self.seq:02d}_{name}.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(record, f, ensure_ascii=False, indent=2)

    def write_summary(self) -> None:
        with open(os.path.join(self.out, "summary.txt"), "w", encoding="utf-8") as f:
            f.write("\n".join(self.summary) + "\n")

    def cmd(self, name: str, body=None, method: str = "POST", timeout: float = 10):
        url = f"http://{self.http}/vcam/cmd.cgi?cmd={name}"
        data = b"" if body is None else json.dumps(body).encode()
        req = urllib.request.Request(url, data=data if method == "POST" else None, method=method)
        req.add_header("sessionid", self.session)
        req.add_header("Cookie", f"SessionID={self.session}")
        req.add_header("Connection", "close")
        if body is not None:
            req.add_header("Content-Type", "application/json")
        record = {"cmd": name, "method": method, "body": body, "session_sent": bool(self.session)}
        t0 = time.monotonic()
        try:
            try:
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    record.update(status=r.status, headers=dict(r.headers))
                    raw = read_capped(r)
            except urllib.error.HTTPError as e:
                record.update(status=e.code, headers=dict(e.headers or {}))
                raw = read_capped(e)
        except Exception as e:  # network errors are findings too
            record.update(error=f"{type(e).__name__}: {e}", ms=round((time.monotonic() - t0) * 1000))
            self.save(name, record)
            self.log(f"{name:28s} ERROR {record['error']}")
            return None
        record["ms"] = round((time.monotonic() - t0) * 1000)
        resp = parse_response(raw)
        record.update(raw=resp.text, parsed=resp.parsed, data_was_string=resp.data_was_string, not_json=resp.not_json)
        self.save(name, record)
        self.log(f"{name:28s} {method} http={record['status']} errcode={resp.errcode} {record['ms']}ms")
        return resp.parsed

    # ---- steps -------------------------------------------------------------

    def login(self, uid: str) -> None:
        self.cmd("query_devinfo")
        self.session = str(data_dict(self.cmd("API_RequestSessionID")).get("acSessionId") or "")
        self.log(f"session obtained: {bool(self.session)}")
        # Does a read work with a session but before the certificate step?
        self.cmd("API_GetBaseInfo")
        self.cmd("API_RequestCertificate", {"user": "admin", "password": "admin", "level": 0, "uid": uid})

    def reads(self):
        base = self.cmd("API_GetBaseInfo")
        for name in ["API_GetStorageInfo", "API_GetCameraState", "API_GetModuleState",
                     "API_GetRearCamConnectInfo", "API_GetRearCamBaseInfo", "API_GetCameraPreview",
                     "APP_AvCapReq", "API_GetEachFileSize", "APP_EventListReq", "APP_LockedListReq",
                     "APP_PlaybackListReq_RearCam", "APP_EventListReq_RearCam"]:
            self.cmd(name)
        self.listing = self.cmd("APP_PlaybackListReq")
        self.mode = play_mode(self.cmd("API_PlayModeQuery"))
        self.cmd("API_GeneralQuery", {"keys": [{"key": k} for k in SETTINGS_KEYS]})
        self.cmd("API_GetLogonRecord", {"num": 6})
        for _ in range(3):
            self.cmd("API_GetMailboxData", timeout=5)
            time.sleep(1)
        # Do public-project style GET requests work too?
        self.cmd("API_GetStorageInfo", method="GET")
        return base

    def stream(self, port: int, seconds: float, hevc: bool) -> None:
        tag = f"tcp{port}"
        raw_path = os.path.join(self.out, f"{tag}.raw")
        es_path = os.path.join(self.out, f"{tag}.{'h265' if hevc else 'h264'}")
        parser = FrameParser()
        stats = {"bytes": 0, "frames": 0, "types": {}, "video_frames": 0, "first_video_nals": None,
                 "other_payload_head": None, "end": "time"}
        try:
            sock = socket.create_connection((self.ip, port), timeout=5)
        except OSError as e:
            self.log(f"{tag}: connect failed: {e}")
            return
        end = time.monotonic() + seconds
        try:
            sock.settimeout(2)
            with open(raw_path, "wb") as raw, open(es_path, "wb") as es:
                while time.monotonic() < end:
                    try:
                        chunk = sock.recv(65536)
                    except socket.timeout:
                        continue
                    except OSError as e:
                        stats["end"] = f"{type(e).__name__}: {e}"
                        break
                    if not chunk:
                        stats["end"] = "closed by camera"
                        break
                    raw.write(chunk)
                    stats["bytes"] += len(chunk)
                    for ftype, payload in parser.feed(chunk):
                        stats["frames"] += 1
                        stats["types"][ftype] = stats["types"].get(ftype, 0) + 1
                        nals = nal_types(payload[:4096], hevc)
                        if nals:
                            stats["video_frames"] += 1
                            if stats["first_video_nals"] is None:
                                stats["first_video_nals"] = nals
                            es.write(payload)
                        elif stats["other_payload_head"] is None:
                            stats["other_payload_head"] = payload[:16].hex(" ")
        finally:
            sock.close()
        with open(raw_path, "rb") as f:
            stats["first_bytes_hex"] = f.read(32).hex(" ")
        stats["resyncs"] = parser.resyncs
        self.log(f"{tag}: {json.dumps(stats)}")

    def rtsp(self) -> None:
        if not shutil.which("ffprobe"):
            self.log("ffprobe missing, RTSP check skipped")
            return
        for url in [f"rtsp://{self.ip}/liveRTSP/av4", f"rtsp://{self.ip}:554/liveRTSP/av4",
                    f"rtsp://{self.ip}/liveRTSP/av5", f"rtsp://{self.ip}:8554/camera"]:
            try:
                p = subprocess.run(
                    ["ffprobe", "-v", "error", "-rtsp_transport", "tcp", "-timeout", "5000000",
                     "-show_entries", "stream=codec_name,width,height,r_frame_rate", "-of", "json", url],
                    capture_output=True, text=True, timeout=15)
                out = p.stdout.strip() if p.returncode == 0 else p.stderr.strip()
                res = f"rc={p.returncode} " + " ".join(out.split())[:400]
            except subprocess.TimeoutExpired:
                res = "timeout"
            self.log(f"RTSP {url}: {res}")

    def range_test(self) -> None:
        names = file_names(getattr(self, "listing", None))
        if not names:
            self.log("range test skipped: no files listed")
            return
        name = names[0]
        url = f"http://{self.http}/{urllib.parse.quote(name.lstrip('/'))}"
        req = urllib.request.Request(url, headers={"Range": "bytes=0-1023", "Connection": "close"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                body = read_capped(r, limit=2048)
                self.log(f"GET <first file> Range: status={r.status} got={len(body)}B "
                         f"content-range={r.headers.get('Content-Range')} accept-ranges={r.headers.get('Accept-Ranges')} "
                         f"type={r.headers.get('Content-Type')} length={r.headers.get('Content-Length')}")
        except Exception as e:
            self.log(f"GET <first file> Range: ERROR {type(e).__name__}: {e}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ip", default="193.168.0.1")
    ap.add_argument("--out", default=os.path.expanduser("~/openddcam-probe/" + dt.datetime.now().strftime("%Y%m%d-%H%M%S")))
    ap.add_argument("--stream-seconds", type=float, default=8)
    ap.add_argument("--no-stream", action="store_true")
    ap.add_argument("--http-port", type=int, default=80, help=argparse.SUPPRESS)
    ap.add_argument("--allow-any-network", action="store_true",
                    help="skip the check that the camera is on the local Wi-Fi (testing against a fake camera only)")
    a = ap.parse_args()

    src = source_address_for(a.ip)
    if not a.allow_any_network and not same_subnet(src, a.ip):
        print(f"Refusing to run: this computer's address towards {a.ip} is {src}, not in the camera's network.\n"
              "Join the camera's Wi-Fi (SSID volvo_... or ps_...) first. 193.168.0.1 is a public internet\n"
              "address, so off the camera's Wi-Fi the login would go to a stranger's server.")
        return 3

    if inside_git_worktree(a.out):
        print(f"Refusing --out {a.out}: it is inside a git repository and the results contain personal data.")
        return 2

    p = Probe(a.ip, a.out, a.http_port)
    p.log(f"OpenDDCam probe {dt.datetime.now().isoformat(timespec='seconds')} ip={a.ip} out={a.out}")
    try:
        p.login(uid=stable_uid())
        base = data_dict(p.reads())
        hevc = str(base.get("preview_enc_type", "0")) == "1"
        p.log(f"model={base.get('model')} version={base.get('version')} preview_enc_type={base.get('preview_enc_type')} mode={p.mode}")
        if not a.no_stream:
            p.rtsp()
            if p.mode != "live":
                p.cmd("APP_PlaybackLiveSwitch", {"switch": "live", "playtime": ""})
            p.stream(6200, a.stream_seconds, hevc)
            p.stream(6202, min(a.stream_seconds, 4), hevc)
        p.range_test()
    except KeyboardInterrupt:
        p.log("interrupted by user")
    except Exception as e:  # keep whatever was collected
        p.log(f"probe crashed: {type(e).__name__}: {e}")
    finally:
        if p.session:
            p.cmd("API_Logout", timeout=5)
        p.write_summary()
    print(f"\nDone. Results: {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
