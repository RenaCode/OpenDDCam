"""Tolerant interpretation of camera responses. Never raises on odd shapes."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any


@dataclass
class Response:
    text: str
    parsed: Any
    errcode: Any
    data_was_string: bool
    not_json: bool


def parse_response(raw: bytes) -> Response:
    text = raw.decode("utf-8", "replace")
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return Response(text, None, None, False, True)
    was_string = False
    if isinstance(parsed, dict) and isinstance(parsed.get("data"), str) and parsed["data"]:
        try:
            parsed["data"] = json.loads(parsed["data"])
            was_string = True
        except json.JSONDecodeError:
            pass
    errcode = parsed.get("errcode") if isinstance(parsed, dict) else None
    return Response(text, parsed, errcode, was_string, False)


def data_dict(parsed: Any) -> dict:
    if isinstance(parsed, dict) and isinstance(parsed.get("data"), dict):
        return parsed["data"]
    return {}


def file_names(parsed: Any) -> list[str]:
    files = data_dict(parsed).get("file")
    if not isinstance(files, list):
        return []
    return [f["name"] for f in files if isinstance(f, dict) and isinstance(f.get("name"), str) and f["name"]]


def play_mode(parsed: Any) -> str | None:
    mode = data_dict(parsed).get("playmode")
    return mode if isinstance(mode, str) else None
