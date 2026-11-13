"""What this Mac is: chip, memory, disk, Thunderbolt ports, RDMA, and live memory use."""

import json
import os
import re
import socket
import subprocess
from functools import lru_cache


def _run(*cmd: str, timeout: float = 10) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def _sysctl(key: str) -> str:
    return _run("sysctl", "-n", key).strip()


@lru_cache(maxsize=1)
def static_info() -> dict:
    model_id = _sysctl("hw.model")
    st = os.statvfs("/")
    gpu_cores = None
    try:
        displays = json.loads(_run("system_profiler", "SPDisplaysDataType", "-json") or "{}")
        for gpu in displays.get("SPDisplaysDataType", []):
            if gpu.get("sppci_cores"):
                gpu_cores = int(gpu["sppci_cores"])
    except Exception:
        pass
    return {
        "name": _run("scutil", "--get", "ComputerName").strip() or socket.gethostname(),
        "host": (_run("scutil", "--get", "LocalHostName").strip() or socket.gethostname().split(".")[0]) + ".local",
        "model_id": model_id,
        "kind": _kind(model_id),
        "chip": _sysctl("machdep.cpu.brand_string"),
        "cpu_cores": int(_sysctl("hw.ncpu") or 0),
        "gpu_cores": gpu_cores,
        "memory_bytes": int(_sysctl("hw.memsize") or 0),
        "disk_bytes": st.f_blocks * st.f_frsize,
        "thunderbolt": thunderbolt_ports(),
    }


def _kind(model_id: str) -> str:
    """hw.model families → the kind of Mac, used for the card's glyph."""
    for prefix, kind in (("MacBookAir", "laptop"), ("MacBookPro", "laptop"), ("Macmini", "mini"),
                         ("iMac", "imac"), ("MacPro", "pro")):
        if model_id.startswith(prefix):
            return kind
    # Apple silicon desktops report "MacNN,N"; Studio and the newer minis share it.
    return "studio" if model_id.startswith("Mac") else "laptop"


def thunderbolt_ports() -> list[dict]:
    try:
        data = json.loads(_run("system_profiler", "SPThunderboltDataType", "-json") or "{}")
    except Exception:
        return []
    ports = []
    for bus in data.get("SPThunderboltDataType", []):
        for key, val in bus.items():
            if not key.startswith("receptacle") or not isinstance(val, dict):
                continue
            speed = val.get("current_speed_key", "")
            m = re.search(r"(\d+)\s*Gb/s", speed)
            gbps = int(m.group(1)) if m else None
            ports.append({
                "id": val.get("receptacle_id_key"),
                "gbps": gbps,
                # 40 Gb/s is TB3/TB4/USB4; TB5 links at 80 (120 boosted).
                "generation": 5 if gbps and gbps >= 80 else 4 if gbps else None,
                "connected": val.get("receptacle_status_key") != "receptacle_no_devices_connected",
            })
    return ports


def rdma_state() -> str:
    """'enabled', 'disabled', or 'unavailable' when the OS has no rdma_ctl."""
    if not os.path.exists("/usr/bin/rdma_ctl"):
        return "unavailable"
    out = _run("rdma_ctl", "status").strip().lower()
    return "enabled" if out.startswith("enabled") else "disabled"


def memory_used_bytes() -> int:
    """Wired + active + compressed pages, the figure Activity Monitor calls Memory Used (roughly)."""
    out = _run("vm_stat", timeout=3)
    page = int(re.search(r"page size of (\d+)", out).group(1)) if "page size" in out else 16384
    pages = {}
    for line in out.splitlines():
        m = re.match(r'"?(.+?)"?:\s+(\d+)\.', line)
        if m:
            pages[m.group(1)] = int(m.group(2))
    used = pages.get("Pages wired down", 0) + pages.get("Anonymous pages", pages.get("Pages active", 0)) \
        + pages.get("Pages occupied by compressor", 0)
    return used * page


def gpu_budget_bytes() -> int:
    """How much memory Metal will let a model take on this Mac (recommendedMaxWorkingSetSize)."""
    try:
        import mlx.core as mx
        return int(mx.device_info()["max_recommended_working_set_size"])
    except Exception:
        return int(static_info()["memory_bytes"] * 0.66)


def disk_free_bytes() -> int:
    st = os.statvfs("/")
    return st.f_bavail * st.f_frsize
