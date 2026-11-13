"""HTTP: the OpenAI-compatible API (/v1/*) for anyone on the network, and the control API
(/pier/*) the app uses. Anything that changes state only answers to this Mac."""

import http.client
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import hardware, models
from .cluster import RANK0_HTTP_PORT, Cluster

STARTED = time.time()


class Node:
    def __init__(self, node_id: str, name: str | None, port: int, runtime, discovery):
        self.id, self.port = node_id, port
        self.name_override = name
        self.runtime, self.discovery = runtime, discovery
        self.cluster = Cluster()

    def peers(self) -> list[dict]:
        return self.discovery.snapshot() if self.discovery else []

    def info(self) -> dict:
        hw = dict(hardware.static_info())
        if self.name_override:
            hw["name"] = self.name_override
        rt = self.runtime
        cl = self.cluster.snapshot()
        return {
            "id": self.id, "port": self.port, **hw,
            "memory_used_bytes": hardware.memory_used_bytes(),
            "gpu_budget_bytes": hardware.gpu_budget_bytes(),
            "model": cl["repo"] if cl else rt.repo if rt.state == "ready" else None,
            "model_state": cl["state"] if cl else rt.state,
            "role": cl["role"] if cl else None,
            "layers": cl["layers"] if cl else None,
        }

    def status(self) -> dict:
        info = self.info()
        rt = self.runtime.snapshot()
        cl = self.cluster.snapshot()
        if cl and cl["role"] == "coordinator":
            # The split model is what this Mac serves; show it as the runtime.
            rt = {**rt, "state": cl["state"], "error": cl["error"], "repo": cl["repo"],
                  "loaded_at": cl["loaded_at"], "weights_bytes": 0, "last_tps": None,
                  "last_prompt_tps": None, "tokens_out": 0}
        peers = self.peers()
        reachable = [p for p in peers if p.get("reachable")]
        # A node on this same Mac shares its RAM, so only other machines add to the pool.
        others = [p for p in reachable if p["link"] != "same"]
        cluster_mem = info["memory_bytes"] + sum(p["info"]["memory_bytes"] for p in others)
        cluster_used = info["memory_used_bytes"] + sum(p["info"]["memory_used_bytes"] for p in others)
        tb = info["thunderbolt"]
        return {
            "node": info,
            "server": {
                "port": self.port,
                "endpoint": f"http://{info['host']}:{self.port}/v1",
                "started_at": STARTED,
                "mode": cl["role"] if cl else "standalone",
            },
            "split": cl,
            "runtime": rt,
            "hardware": {
                "thunderbolt_ports": len(tb),
                "thunderbolt_generation": max((p["generation"] or 0 for p in tb), default=0) or None,
                "rdma": hardware.rdma_state(),
                "disk_free_bytes": hardware.disk_free_bytes(),
            },
            "peers": peers,
            "cluster": {"nodes": 1 + len(reachable), "machines": 1 + len(others), "memory_bytes": cluster_mem,
                        "memory_used_bytes": cluster_used},
            "downloads": models.downloads.snapshot(),
        }


def make_handler(node: Node):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "pierd/0.1"

        def log_message(self, *a):
            if os.environ.get("PIER_LOG"):
                super().log_message(*a)

        # ---- plumbing
        def _json(self, code: int, body) -> None:
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(data)

        def _error(self, code: int, message: str, kind: str = "invalid_request_error"):
            self._json(code, {"error": {"message": message, "type": kind}})

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n) or b"{}") if n else {}

        def _local(self) -> bool:
            return self.client_address[0] in ("127.0.0.1", "::1")

        def do_OPTIONS(self):
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Content-Length", "0")
            self.end_headers()

        # ---- routes
        def do_GET(self):
            url = urlparse(self.path)
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            try:
                if url.path == "/pier/info":
                    return self._json(200, node.info())
                if url.path == "/pier/status":
                    return self._json(200, node.status())
                if url.path == "/pier/models/local":
                    return self._json(200, models.list_local())
                if url.path == "/pier/models/search":
                    return self._json(200, models.search(q.get("q", ""), int(q.get("limit", 40))))
                if url.path in ("/v1/models", "/models") and node.cluster.role == "coordinator":
                    return self._proxy("GET", url.path, b"")
                if url.path in ("/v1/models", "/models"):
                    rt = node.runtime
                    data = [{"id": rt.repo, "object": "model", "created": int(rt.loaded_at or 0),
                             "owned_by": "pier"}] if rt.state == "ready" else []
                    return self._json(200, {"object": "list", "data": data})
                self._error(404, f"No route {url.path}")
            except Exception as e:
                self._error(500, str(e), "server_error")

        def do_POST(self):
            path = urlparse(self.path).path
            try:
                body = self._body()
            except json.JSONDecodeError:
                return self._error(400, "Body is not JSON")
            try:
                if path in ("/v1/chat/completions", "/chat/completions", "/v1/completions"):
                    if node.cluster.role == "coordinator":
                        return self._proxy("POST", path, json.dumps(body).encode())
                    if node.cluster.role == "member":
                        return self._error(409, "This Mac is serving part of a split model; "
                                                "send requests to the Mac that started it", "server_error")
                    return self._chat(body)
                if not path.startswith("/pier/"):
                    return self._error(404, f"No route {path}")
                if path in ("/pier/cluster/join", "/pier/cluster/leave"):
                    return self._cluster_member(path, body)
                if not self._local():
                    return self._error(403, "Control API only answers to this Mac")
                repo = body.get("repo", "")
                if path == "/pier/cluster/start":
                    peers = [p for p in node.peers() if p.get("reachable")]
                    if body.get("peers"):
                        peers = [p for p in peers if p["id"] in body["peers"]]
                    local = {m["repo"]: m for m in models.list_local()}
                    weights = local.get(repo, {}).get("size_bytes") or models._size_cache.get(repo)
                    node.runtime.unload()
                    node.cluster.start(repo, peers, weights)
                    return self._json(200, {"ok": True})
                if path == "/pier/cluster/stop":
                    node.cluster.stop()
                    return self._json(200, {"ok": True})
                if path == "/pier/load":
                    node.cluster.stop()
                    local = {m["repo"]: m for m in models.list_local()}
                    if repo not in local:
                        return self._error(404, f"{repo} isn't downloaded")
                    if local[repo]["fit"] == "too_big":
                        return self._error(409, "Too big for this Mac's memory")
                    node.runtime.load(repo)
                elif path == "/pier/unload":
                    node.runtime.unload()
                elif path == "/pier/models/download":
                    models.downloads.start(repo)
                elif path == "/pier/models/cancel":
                    models.downloads.cancel(repo)
                    models.dismiss_failed(repo)
                elif path == "/pier/models/delete":
                    if node.runtime.repo == repo:
                        return self._error(409, "Unload it first")
                    models.delete(repo)
                else:
                    return self._error(404, f"No route {path}")
                self._json(200, {"ok": True})
            except Exception as e:
                self._error(500, str(e), "server_error")

        # ---- cluster membership (from the coordinating Mac)
        def _cluster_member(self, path, body):
            ip = self.client_address[0]
            known = {p["ip"] for p in node.peers()}
            if not self._local() and ip not in known:
                return self._error(403, "Only Macs running Pier on this network can do that")
            if path.endswith("/join"):
                node.runtime.unload()
                node.cluster.join(int(body["rank"]), body["hosts"], body["split"], body["repo"], ip)
            else:
                node.cluster.stop(notify=False)
            self._json(200, {"ok": True})

        # ---- proxy to the rank-0 shard (mlx-lm's server)
        def _proxy(self, method, path, data):
            if node.cluster.shard is None or node.cluster.shard.state != "ready":
                return self._error(503, "The split model is still loading", "server_error")
            conn = http.client.HTTPConnection("127.0.0.1", RANK0_HTTP_PORT, timeout=600)
            try:
                conn.request(method, path, body=data or None, headers={"Content-Type": "application/json"})
                resp = conn.getresponse()
                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() not in ("transfer-encoding", "connection", "content-length", "server", "date"):
                        self.send_header(k, v)
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                while chunk := resp.read1(65536):
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                conn.close()

        # ---- OpenAI chat completions
        def _chat(self, body: dict):
            rt = node.runtime
            if rt.state != "ready":
                return self._error(503, "No model is loaded", "server_error")
            messages = body.get("messages")
            if not isinstance(messages, list) or not messages:
                return self._error(400, "messages is required")
            for m in messages:  # flatten OpenAI content parts to text
                if isinstance(m.get("content"), list):
                    m["content"] = "".join(p.get("text", "") for p in m["content"] if isinstance(p, dict))
            stream = rt.generate(messages, body)
            created, model = int(time.time()), rt.repo

            if not body.get("stream"):
                text, usage, reason = "", {}, "stop"
                for kind, val in stream:
                    if kind == "text":
                        text += val
                    elif kind == "error":
                        return self._error(500, val, "server_error")
                    else:
                        reason, usage = val["finish_reason"], val
                return self._json(200, {
                    "id": stream.id, "object": "chat.completion", "created": created, "model": model,
                    "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                                 "finish_reason": reason}],
                    "usage": {"prompt_tokens": usage.get("prompt_tokens", 0),
                              "completion_tokens": usage.get("completion_tokens", 0),
                              "total_tokens": usage.get("prompt_tokens", 0) + usage.get("completion_tokens", 0)},
                })

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

            def chunk(delta, reason=None, extra=None):
                obj = {"id": stream.id, "object": "chat.completion.chunk", "created": created, "model": model,
                       "choices": [{"index": 0, "delta": delta, "finish_reason": reason}]}
                if extra:
                    obj.update(extra)
                self.wfile.write(f"data: {json.dumps(obj)}\n\n".encode())
                self.wfile.flush()

            try:
                chunk({"role": "assistant", "content": ""})
                for kind, val in stream:
                    if kind == "text":
                        chunk({"content": val})
                    elif kind == "error":
                        self.wfile.write(f"data: {json.dumps({'error': {'message': val}})}\n\n".encode())
                        break
                    else:
                        usage = {"prompt_tokens": val["prompt_tokens"], "completion_tokens": val["completion_tokens"],
                                 "total_tokens": val["prompt_tokens"] + val["completion_tokens"]}
                        chunk({}, val["finish_reason"], {"usage": usage})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                stream.cancelled = True  # client went away; stop generating for it

    return Handler


def serve(node: Node) -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer(("0.0.0.0", node.port), make_handler(node))
    httpd.daemon_threads = True
    return httpd
