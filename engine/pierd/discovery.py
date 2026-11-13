"""Bonjour: advertise this node as _pier._tcp and keep a live list of the other nodes,
with how each one is reached (Thunderbolt Bridge, Wi-Fi, Ethernet, or the same Mac)."""

import json
import re
import socket
import subprocess
import threading
import time
import urllib.request

from zeroconf import IPVersion, ServiceBrowser, ServiceInfo, ServiceListener, Zeroconf

SERVICE = "_pier._tcp.local."


def _local_addresses() -> set[str]:
    out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    return set(re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out))


def _hardware_ports() -> dict[str, str]:
    """bridge0 → 'Thunderbolt Bridge', en0 → 'Wi-Fi', …"""
    out = subprocess.run(["networksetup", "-listallhardwareports"], capture_output=True, text=True).stdout
    ports, name = {}, None
    for line in out.splitlines():
        if line.startswith("Hardware Port:"):
            name = line.split(":", 1)[1].strip()
        elif line.startswith("Device:") and name:
            ports[line.split(":", 1)[1].strip()] = name
    return ports


def _link_for(ip: str, local: set[str], ports: dict[str, str]) -> str:
    if ip in local or ip.startswith("127."):
        return "same"
    out = subprocess.run(["route", "-n", "get", ip], capture_output=True, text=True).stdout
    m = re.search(r"interface:\s*(\S+)", out)
    iface = m.group(1) if m else ""
    port = ports.get(iface, iface)
    if "Thunderbolt" in port or iface.startswith("bridge"):
        return "thunderbolt"
    if "Wi-Fi" in port:
        return "wifi"
    return "ethernet" if port else "network"


class Discovery(ServiceListener):
    def __init__(self, node_id: str, name: str, port: int):
        self.node_id, self.name, self.port = node_id, name, port
        self.peers: dict[str, dict] = {}   # service name → peer
        self.lock = threading.Lock()
        self.zc = Zeroconf(ip_version=IPVersion.V4Only)
        self._ports = _hardware_ports()
        self._local = _local_addresses()

    def start(self):
        addrs = [socket.inet_aton(a) for a in sorted(self._local) if not a.startswith("127.")]
        safe = re.sub(r"[^A-Za-z0-9 -]", "", self.name)[:40] or "Mac"
        self.info = ServiceInfo(SERVICE, f"{safe} {self.node_id[:6]}.{SERVICE}", port=self.port,
                                properties={"id": self.node_id}, addresses=addrs)
        self.zc.register_service(self.info, allow_name_change=True)
        ServiceBrowser(self.zc, SERVICE, self)
        threading.Thread(target=self._poll, daemon=True).start()

    def stop(self):
        try:
            self.zc.unregister_service(self.info)
            self.zc.close()
        except Exception:
            pass

    # ServiceListener
    def add_service(self, zc, type_, name):
        self._resolve(zc, type_, name)

    def update_service(self, zc, type_, name):
        self._resolve(zc, type_, name)

    def remove_service(self, zc, type_, name):
        with self.lock:
            self.peers.pop(name, None)

    def _resolve(self, zc, type_, name):
        info = zc.get_service_info(type_, name, timeout=3000)
        if not info:
            return
        peer_id = (info.properties or {}).get(b"id", b"").decode()
        if not peer_id or peer_id == self.node_id:
            return
        ips = info.parsed_addresses()
        # Prefer the Thunderbolt Bridge address when a peer is reachable over several links.
        self._local = _local_addresses()
        ranked = sorted(ips, key=lambda ip: ["thunderbolt", "same", "ethernet", "wifi", "network"]
                        .index(_link_for(ip, self._local, self._ports)))
        if not ranked:
            return
        ip = ranked[0]
        with self.lock:
            prev = self.peers.get(name, {})
            self.peers[name] = {**prev, "id": peer_id, "ip": ip, "port": info.port,
                                "link": _link_for(ip, self._local, self._ports)}

    def _poll(self):
        """Fetch each peer's card info so the canvas can draw it."""
        while True:
            with self.lock:
                items = list(self.peers.items())
            for name, peer in items:
                try:
                    host = "127.0.0.1" if peer["link"] == "same" else peer["ip"]
                    t0 = time.time()
                    with urllib.request.urlopen(f"http://{host}:{peer['port']}/pier/info", timeout=2) as r:
                        info = json.loads(r.read())
                    peer = {**peer, "info": info, "seen": time.time(), "reachable": True}
                    peer["latency_ms"] = round((time.time() - t0) * 1000, 1)
                except Exception:
                    peer = {**peer, "reachable": False}
                with self.lock:
                    if name in self.peers:
                        self.peers[name] = peer
            time.sleep(2)

    def snapshot(self) -> list[dict]:
        with self.lock:
            return [p for p in self.peers.values() if "info" in p]
