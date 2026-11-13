"""Cluster mode: one model split across Macs by layers, in proportion to each Mac's memory.

The Mac that starts it is rank 0: it runs the last layers, samples, and serves /v1 (pierd
proxies to its shard). Every other Mac joins as a later rank and runs earlier layers. Each
rank is a `python -m pierd.shard` child process talking mx.distributed's ring backend over TCP.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

from . import hardware

RANK0_HTTP_PORT = 52510
RING_PORT_BASE = 52520
LOG_DIR = Path.home() / "Library/Logs/Pier"


def plan_split(num_layers: int, budgets: list[int], weights_bytes: int | None) -> list[int]:
    """Layers per rank (rank 0 first), proportional to each node's Metal budget.
    Every rank keeps its own copy of the embeddings and head, so those don't scale."""
    total = sum(budgets)
    raw = [num_layers * b / total for b in budgets]
    split = [max(1, int(r)) for r in raw]
    # Hand the leftover layers to whoever was rounded down the most.
    while sum(split) < num_layers:
        i = max(range(len(split)), key=lambda k: raw[k] - split[k])
        split[i] += 1
    while sum(split) > num_layers:
        i = max(range(len(split)), key=lambda k: split[k] - raw[k])
        split[i] -= 1
    if weights_bytes:
        per_layer = weights_bytes / num_layers
        for layers, budget in zip(split, budgets):
            if layers * per_layer * 1.15 > budget:
                raise RuntimeError("Too big even for the whole cluster")
    return split


class Shard:
    """A running shard process on this Mac, and what its log says."""

    def __init__(self, rank: int, hosts: list[list[str]], split: list[int], repo: str):
        self.rank, self.split, self.repo = rank, split, repo
        self.state, self.error, self.layers = "loading", None, None
        self.started = time.time()
        self.loaded_at = None
        fd, self.hostfile = tempfile.mkstemp(prefix="pier-hosts-", suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump(hosts, f)
        env = {**os.environ, "MLX_RANK": str(rank), "MLX_HOSTFILE": self.hostfile,
               "PIER_SPLIT": json.dumps(split), "PIER_REPO": repo,
               "PIER_SHARD_PORT": str(RANK0_HTTP_PORT), "PYTHONUNBUFFERED": "1"}
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        self.log = open(LOG_DIR / f"shard-rank{rank}.log", "w")
        self.proc = subprocess.Popen([sys.executable, "-m", "pierd.shard"], env=env,
                                     cwd=Path(__file__).resolve().parent.parent,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        last = ""
        for line in self.proc.stdout:
            self.log.write(line)
            self.log.flush()
            m = re.search(r"rank \d+: layers (\d+)-(\d+)", line)
            if m:
                self.layers = [int(m.group(1)), int(m.group(2))]
                self.state, self.loaded_at = "ready", time.time()
            if re.search(r"\w+(Error|Exception):", line):
                last = line.strip()
        code = self.proc.wait()
        if self.state != "stopped":
            self.state = "error"
            self.error = last or f"Shard exited ({code})"

    def stop(self):
        self.state = "stopped"
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        try:
            os.unlink(self.hostfile)
        except OSError:
            pass

    def snapshot(self) -> dict:
        return {"rank": self.rank, "state": self.state, "error": self.error, "layers": self.layers,
                "repo": self.repo, "split": self.split, "loaded_at": self.loaded_at}


class Cluster:
    def __init__(self):
        self.shard: Shard | None = None
        self.role = None            # None | "coordinator" | "member"
        self.members: list[dict] = []  # coordinator only: the peers it enlisted
        self.coordinator: str | None = None
        self.lock = threading.Lock()

    # ---- coordinator side

    def start(self, repo: str, peers: list[dict], weights_bytes: int | None):
        from huggingface_hub import hf_hub_download

        if not peers:
            raise RuntimeError("No other Macs to split across")
        with open(hf_hub_download(repo, "config.json")) as f:
            cfg = json.load(f)
        cfg = cfg.get("text_config", cfg)
        num_layers = cfg["num_hidden_layers"]
        budgets = [hardware.gpu_budget_bytes()] + [p["info"]["gpu_budget_bytes"] for p in peers]
        split = plan_split(num_layers, budgets, weights_bytes)

        # Ring addresses: loopback when every rank is on this Mac, else the LAN address this Mac
        # uses to reach the peers.
        if all(p["link"] == "same" for p in peers):
            ips = ["127.0.0.1"] * (1 + len(peers))
        else:
            remote = next(p for p in peers if p["link"] != "same")
            mine = _source_ip(remote["ip"])
            ips = [mine] + [mine if p["link"] == "same" else p["ip"] for p in peers]
        hosts = [[f"{ip}:{RING_PORT_BASE + r}"] for r, ip in enumerate(ips)]

        self.stop()
        with self.lock:
            self.role, self.members = "coordinator", []
            for rank, peer in enumerate(peers, start=1):
                host = "127.0.0.1" if peer["link"] == "same" else peer["ip"]
                _post(f"http://{host}:{peer['port']}/pier/cluster/join",
                      {"rank": rank, "hosts": hosts, "split": split, "repo": repo})
                self.members.append({**peer, "rank": rank, "layers_count": split[rank]})
            self.shard = Shard(0, hosts, split, repo)

    # ---- member side

    def join(self, rank: int, hosts, split, repo: str, coordinator: str):
        self.stop(notify=False)
        with self.lock:
            self.role, self.coordinator = "member", coordinator
            self.shard = Shard(rank, hosts, split, repo)

    def stop(self, notify: bool = True):
        with self.lock:
            if self.shard:
                self.shard.stop()
            if notify and self.role == "coordinator":
                for m in self.members:
                    host = "127.0.0.1" if m["link"] == "same" else m["ip"]
                    try:
                        _post(f"http://{host}:{m['port']}/pier/cluster/leave", {})
                    except Exception:
                        pass
            self.shard, self.role, self.members, self.coordinator = None, None, [], None

    def snapshot(self) -> dict | None:
        if not self.shard:
            return None
        return {"role": self.role, **self.shard.snapshot(),
                "members": [{"id": m["id"], "rank": m["rank"]} for m in self.members]}


def _source_ip(dest: str) -> str:
    out = subprocess.run(["route", "-n", "get", dest], capture_output=True, text=True).stdout
    m = re.search(r"interface:\s*(\S+)", out)
    if m:
        addr = subprocess.run(["ipconfig", "getifaddr", m.group(1)], capture_output=True, text=True).stdout.strip()
        if addr:
            return addr
    raise RuntimeError(f"No route to {dest}")


def _post(url: str, body: dict):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read() or b"{}")
