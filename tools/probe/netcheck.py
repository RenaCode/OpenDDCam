"""Make sure the probe only talks to a camera on the local Wi-Fi.

The camera's address 193.168.0.1 is a public internet address. Off the camera's
network, requests (including the vendor-default login) would go to a stranger's
host. We therefore require that our own source address towards the camera is in
the camera's /24.
"""

from __future__ import annotations

import ipaddress
import socket


def same_subnet(src, dst: str, prefix: int = 24) -> bool:
    try:
        s = ipaddress.ip_address(src)
        d = ipaddress.ip_address(dst)
    except (TypeError, ValueError):
        return False
    if s.version != 4 or d.version != 4:
        return False
    return s in ipaddress.ip_network(f"{d}/{prefix}", strict=False)


def source_address_for(dst: str) -> str | None:
    """Local address the OS would use to reach dst. A UDP connect sends nothing."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect((dst, 9))
            return s.getsockname()[0]
    except OSError:
        return None
