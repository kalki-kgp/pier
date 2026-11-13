"""Model catalogue (mlx-community on Hugging Face), local cache, and downloads.

Downloads run in a child process so they can be cancelled by killing it; progress is the
size of the repo's blob directory against the total the Hub reports.
"""

import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

from huggingface_hub import HfApi, scan_cache_dir
from huggingface_hub.constants import HF_HUB_CACHE

from . import hardware

api = HfApi()

_DTYPE_BYTES = {"F64": 8, "I64": 8, "U64": 8, "F32": 4, "I32": 4, "U32": 4, "BF16": 2, "F16": 2,
                "I16": 2, "U16": 2, "F8_E4M3": 1, "F8_E5M2": 1, "I8": 1, "U8": 1, "BOOL": 1}

_search_cache: dict[str, tuple[float, list]] = {}
_size_cache: dict[str, int] = {}


def _repo_dir(repo: str) -> Path:
    return Path(HF_HUB_CACHE) / ("models--" + repo.replace("/", "--"))


def _weights_bytes(safetensors, config: dict | None) -> int | None:
    """Weight bytes from the Hub's parameter counts. The Hub counts quantized weights as
    unpacked parameters (tagged U32), so they cost bits/8 each plus a bf16 scale and bias
    per group, read from the repo's quantization config."""
    if not safetensors or not getattr(safetensors, "parameters", None):
        return None
    q = (config or {}).get("quantization") or (config or {}).get("quantization_config") or {}
    bits, group = q.get("bits"), q.get("group_size") or 64
    total = 0.0
    for dtype, n in safetensors.parameters.items():
        if dtype == "U32" and bits:
            total += n * (bits / 8 + 4 / group)
        else:
            total += n * _DTYPE_BYTES.get(dtype, 2)
    return int(total)


def _fill_quantization(found) -> None:
    """The Hub's expanded config sometimes leaves out the quantization block; read it from
    the repo's own config.json (small, fetched in parallel, cached by the hub client)."""
    from concurrent.futures import ThreadPoolExecutor
    from huggingface_hub import hf_hub_download

    def needs(m):
        cfg = m.config or {}
        params = getattr(m.safetensors, "parameters", None) or {}
        return "U32" in params and not (cfg.get("quantization") or cfg.get("quantization_config"))

    def fetch(m):
        try:
            with open(hf_hub_download(m.id, "config.json")) as f:
                cfg = json.load(f)
            m.config = {**(m.config or {}), **cfg}
        except Exception:
            pass

    todo = [m for m in found if needs(m)]
    if todo:
        with ThreadPoolExecutor(8) as pool:
            list(pool.map(fetch, todo))


def model_type(repo: str) -> str | None:
    try:
        from huggingface_hub import hf_hub_download
        with open(hf_hub_download(repo, "config.json")) as f:
            return json.load(f).get("model_type")
    except Exception:
        return None


_split_cache: dict[str, bool] = {}


def splittable(mtype: str | None) -> bool:
    """Whether mlx-lm can pipeline this architecture across Macs: its model module defines a
    class built on PipelineMixin."""
    if not mtype:
        return False
    if mtype not in _split_cache:
        try:
            import importlib
            from mlx_lm.models.pipeline import PipelineMixin
            import sys
            mod = importlib.import_module(f"mlx_lm.models.{mtype}")
            # A family can reuse another's classes (qwen3_5_moe builds on qwen3_5), so look in
            # every module along the Model class's ancestry.
            mods = {sys.modules[c.__module__] for c in getattr(mod, "Model", object).__mro__
                    if c.__module__.startswith("mlx_lm.models")} | {mod}
            _split_cache[mtype] = any(isinstance(v, type) and issubclass(v, PipelineMixin) and v is not PipelineMixin
                                      for m in mods for v in vars(m).values())
        except Exception:
            _split_cache[mtype] = False
    return _split_cache[mtype]


def fit(size_bytes: int | None, budget: int) -> str:
    """'fits' / 'tight' / 'too_big' against this Mac's Metal working-set budget.
    The model needs headroom beyond its weights for the KV cache and activations."""
    if not size_bytes:
        return "unknown"
    if size_bytes * 1.15 <= budget:
        return "fits"
    if size_bytes <= budget:
        return "tight"
    return "too_big"


def search(query: str, limit: int = 40) -> list[dict]:
    key = f"{query}|{limit}"
    hit = _search_cache.get(key)
    if hit and time.time() - hit[0] < 300:
        rows = hit[1]
    else:
        found = api.list_models(author="mlx-community", search=query or None, sort="downloads",
                                limit=limit, pipeline_tag="text-generation",
                                expand=["safetensors", "config", "downloads", "likes", "lastModified"])
        found = list(found)
        _fill_quantization(found)
        rows = []
        for m in found:
            archs = (m.config or {}).get("architectures") or []
            if archs and not any(a.endswith(("ForCausalLM", "ForConditionalGeneration")) for a in archs):
                continue  # embedding / reranker heads can't chat
            size = _weights_bytes(m.safetensors, m.config)
            if size:
                _size_cache[m.id] = size
            rows.append({"repo": m.id, "size_bytes": size, "downloads": m.downloads or 0,
                         "likes": m.likes or 0,
                         "splittable": splittable((m.config or {}).get("model_type"))})
        _search_cache[key] = (time.time(), rows)
    budget = hardware.gpu_budget_bytes()
    local = {m["repo"] for m in list_local()}
    return [{**r, "fit": fit(r["size_bytes"], budget), "downloaded": r["repo"] in local,
             "downloading": r["repo"] in downloads.active} for r in rows]


def list_local() -> list[dict]:
    """Repos in the HF cache that look like complete MLX language models."""
    try:
        info = scan_cache_dir()
    except Exception:
        return []
    budget = hardware.gpu_budget_bytes()
    out = []
    for repo in info.repos:
        if repo.repo_type != "model" or repo.repo_id in downloads.active:
            continue
        rev = max(repo.revisions, key=lambda r: r.last_modified, default=None)
        if rev is None:
            continue
        names = {f.file_name for f in rev.files}
        if "config.json" not in names or not any(n.endswith(".safetensors") for n in names):
            continue
        if not any(n.startswith("tokenizer") for n in names):
            continue  # audio/vision-only checkpoints (whisper, mimi) ship no tokenizer
        if not _complete(rev.snapshot_path, names):
            continue  # a cancelled download leaves some shards behind
        size = sum(f.size_on_disk for f in rev.files if f.file_name.endswith(".safetensors"))
        try:
            mtype = json.loads((rev.snapshot_path / "config.json").read_text()).get("model_type")
        except Exception:
            mtype = None
        out.append({"repo": repo.repo_id, "size_bytes": size, "disk_bytes": repo.size_on_disk,
                    "splittable": splittable(mtype),
                    "fit": fit(size, budget), "path": str(rev.snapshot_path)})
    return sorted(out, key=lambda m: m["repo"].lower())


def _complete(snapshot: Path, names: set[str]) -> bool:
    index = snapshot / "model.safetensors.index.json"
    if not index.exists():
        return True
    try:
        shards = set(json.loads(index.read_text())["weight_map"].values())
    except Exception:
        return False
    return shards <= names


def delete(repo: str) -> None:
    d = _repo_dir(repo)
    if d.exists():
        shutil.rmtree(d)


class Downloads:
    def __init__(self):
        self.active: dict[str, dict] = {}
        self.lock = threading.Lock()

    def start(self, repo: str) -> None:
        with self.lock:
            if repo in self.active:
                return
            self.active[repo] = {"repo": repo, "total": _size_cache.get(repo), "done": 0,
                                 "state": "starting", "error": None, "proc": None}
        threading.Thread(target=self._run, args=(repo,), daemon=True).start()

    def cancel(self, repo: str) -> None:
        with self.lock:
            job = self.active.get(repo)
        if job and job["proc"]:
            job["state"] = "cancelled"
            job["proc"].kill()

    def snapshot(self) -> list[dict]:
        with self.lock:
            return [{k: v for k, v in j.items() if k != "proc"} for j in self.active.values()]

    def _run(self, repo: str) -> None:
        job = self.active[repo]
        try:
            info = api.model_info(repo, files_metadata=True)
            job["total"] = sum(s.size or 0 for s in info.siblings) or job["total"]
            free = hardware.disk_free_bytes()
            if job["total"] and job["total"] > free - 2 * 1024**3:
                raise RuntimeError(f"Needs {job['total'] / 1e9:.1f} GB, {free / 1e9:.1f} GB free")
            code = ("import sys; from huggingface_hub import snapshot_download;"
                    "snapshot_download(sys.argv[1], allow_patterns=['*.json','*.safetensors','*.py',"
                    "'*.model','*.tiktoken','*.txt','*.jinja'])")
            proc = subprocess.Popen([sys.executable, "-c", code, repo],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            job["proc"], job["state"] = proc, "downloading"
            blobs = _repo_dir(repo) / "blobs"
            while proc.poll() is None:
                job["done"] = _dir_bytes(blobs)
                time.sleep(0.5)
            if job["state"] == "cancelled":
                return
            if proc.returncode != 0:
                err = (proc.stderr.read() or "").strip().splitlines()
                raise RuntimeError(err[-1] if err else f"exit {proc.returncode}")
            job["done"], job["state"] = job["total"] or _dir_bytes(blobs), "done"
        except Exception as e:
            job["state"], job["error"] = "failed", str(e)
        finally:
            time.sleep(1.5)  # let the UI see the final state before the row turns local
            with self.lock:
                if self.active.get(repo) is job and job["state"] != "failed":
                    del self.active[repo]


def _dir_bytes(path: Path) -> int:
    total = 0
    if path.exists():
        for f in path.iterdir():
            try:
                total += f.stat().st_size
            except FileNotFoundError:
                pass
    return total


downloads = Downloads()


def dismiss_failed(repo: str) -> None:
    with downloads.lock:
        job = downloads.active.get(repo)
        if job and job["state"] in ("failed", "cancelled"):
            del downloads.active[repo]
