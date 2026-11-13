"""pierd — run with `python -m pierd`.

PIER_PORT (default 52500), PIER_NAME and PIER_NODE_ID override the defaults; a second node on
the same Mac (for testing cluster views) needs its own port and node id.
"""

import os
import signal
import sys
import uuid
from pathlib import Path

from . import hardware
from .discovery import Discovery
from .runtime import Runtime
from .server import Node, serve


def node_id() -> str:
    if os.environ.get("PIER_NODE_ID"):
        return os.environ["PIER_NODE_ID"]
    path = Path.home() / "Library/Application Support/Pier/node-id"
    if path.exists():
        return path.read_text().strip()
    path.parent.mkdir(parents=True, exist_ok=True)
    nid = uuid.uuid4().hex
    path.write_text(nid)
    return nid


def main():
    port = int(os.environ.get("PIER_PORT", "52500"))
    name = os.environ.get("PIER_NAME")
    nid = node_id()
    hardware.static_info()  # warm the system_profiler calls before the first request
    runtime = Runtime()
    discovery = None
    if not os.environ.get("PIER_NO_BONJOUR"):
        discovery = Discovery(nid, name or hardware.static_info()["name"], port)
    node = Node(nid, name, port, runtime, discovery)
    httpd = serve(node)
    if discovery:
        discovery.start()

    def stop(*_):
        node.cluster.stop()  # takes the shard processes down and tells members to leave
        if discovery:
            discovery.stop()
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    # The app passes its pid; if it dies without stopping us, we go too.
    parent = os.environ.get("PIER_PARENT_PID")
    if parent:
        import threading, time

        def watch():
            while True:
                try:
                    os.kill(int(parent), 0)
                except OSError:
                    stop()
                time.sleep(2)
        threading.Thread(target=watch, daemon=True).start()
    print(f"pierd {nid[:6]} on :{port}", file=sys.stderr, flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
