"""The one thread that touches MLX. MLX streams are thread-local, so HTTP threads only queue
jobs here and read results off a per-request queue."""

import gc
import queue
import threading
import time
import uuid

import mlx.core as mx
from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_logits_processors, make_sampler

from . import hardware


class Cancelled(Exception):
    pass


class Runtime:
    def __init__(self):
        self.jobs: queue.Queue = queue.Queue()
        self.model = None
        self.tokenizer = None
        self.repo: str | None = None
        self.state = "idle"          # idle | loading | ready | error
        self.error: str | None = None
        self.loaded_at: float | None = None
        self.weights_bytes = 0
        self.active = 0
        self.queued = 0
        self.served = 0
        self.tokens_out = 0
        self.last_tps: float | None = None
        self.last_prompt_tps: float | None = None
        self.peak_bytes = 0
        threading.Thread(target=self._loop, name="mlx", daemon=True).start()

    # -- called from HTTP threads -------------------------------------------------

    def load(self, repo: str) -> None:
        if self.state == "loading":
            return
        self.state, self.error = "loading", None
        self.jobs.put(("load", repo))

    def unload(self) -> None:
        self.jobs.put(("unload", None))

    def generate(self, messages: list[dict], params: dict) -> "Stream":
        if self.state != "ready":
            raise RuntimeError("No model is loaded")
        s = Stream()
        self.queued += 1
        self.jobs.put(("generate", (messages, params, s)))
        return s

    def snapshot(self) -> dict:
        return {
            "state": self.state, "error": self.error, "repo": self.repo,
            "loaded_at": self.loaded_at, "weights_bytes": self.weights_bytes,
            "active": self.active, "queued": self.queued, "served": self.served,
            "tokens_out": self.tokens_out, "last_tps": self.last_tps,
            "last_prompt_tps": self.last_prompt_tps, "peak_bytes": self.peak_bytes,
            "metal_active_bytes": mx.get_active_memory() if self.model is not None else 0,
        }

    # -- worker -------------------------------------------------------------------

    def _loop(self):
        while True:
            kind, arg = self.jobs.get()
            try:
                if kind == "load":
                    self._load(arg)
                elif kind == "unload":
                    self._unload()
                elif kind == "generate":
                    self._generate(*arg)
            except Exception as e:  # keep the worker alive whatever a job does
                if kind == "load":
                    self._unload()
                    self.state, self.error = "error", str(e)
                elif kind == "generate":
                    arg[2].fail(str(e))

    def _unload(self):
        self.model = self.tokenizer = self.repo = self.loaded_at = None
        self.weights_bytes = 0
        gc.collect()
        mx.clear_cache()
        if self.state != "loading":
            self.state = "idle"

    def _load(self, repo: str):
        self._unload()
        self.state = "loading"
        budget = hardware.gpu_budget_bytes()
        model, tokenizer = load(repo)
        weights = sum(v.nbytes for _, v in _flatten(model.parameters()))
        if weights > budget:
            del model, tokenizer
            raise RuntimeError(f"Model needs {weights / 1e9:.1f} GB; this Mac can give it {budget / 1e9:.1f} GB")
        mx.eval(model.parameters())
        self.model, self.tokenizer, self.repo = model, tokenizer, repo
        self.weights_bytes = weights
        self.loaded_at = time.time()
        mx.reset_peak_memory()
        self.state = "ready"

    def _generate(self, messages, params, s: "Stream"):
        self.queued -= 1
        if s.cancelled:
            return
        self.active += 1
        try:
            tok = self.tokenizer
            template_kwargs = dict(params.get("chat_template_kwargs") or {})
            prompt = tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=True,
                                             **template_kwargs)
            sampler = make_sampler(temp=float(params.get("temperature", 0.7)),
                                   top_p=float(params.get("top_p", 0.0) or 0.0),
                                   top_k=int(params.get("top_k", 0) or 0),
                                   min_p=float(params.get("min_p", 0.0) or 0.0))
            processors = make_logits_processors(repetition_penalty=params.get("repetition_penalty"))
            max_tokens = int(params.get("max_tokens") or params.get("max_completion_tokens") or 2048)
            stops = params.get("stop") or []
            stops = [stops] if isinstance(stops, str) else stops
            if params.get("seed") is not None:
                mx.random.seed(int(params["seed"]))

            text, last = "", None
            for r in stream_generate(self.model, tok, prompt, max_tokens=max_tokens,
                                     sampler=sampler, logits_processors=processors):
                if s.cancelled:
                    raise Cancelled()
                last = r
                text += r.text
                hit = next((x for x in stops if x and x in text), None)
                if hit:
                    cut = text.index(hit)
                    s.put(r.text[: max(0, len(r.text) - (len(text) - cut))])
                    last.finish_reason = "stop"
                    break
                s.put(r.text)
            if last is not None:
                self.tokens_out += last.generation_tokens
                self.last_tps = last.generation_tps
                self.last_prompt_tps = last.prompt_tps
                self.peak_bytes = max(self.peak_bytes, int(last.peak_memory * 1e9))
                s.finish(last.finish_reason or "stop", last.prompt_tokens, last.generation_tokens)
            else:
                s.finish("stop", len(prompt), 0)
            self.served += 1
        except Cancelled:
            pass
        finally:
            self.active -= 1


def _flatten(tree, prefix=""):
    if isinstance(tree, dict):
        for k, v in tree.items():
            yield from _flatten(v, f"{prefix}{k}.")
    elif isinstance(tree, list):
        for i, v in enumerate(tree):
            yield from _flatten(v, f"{prefix}{i}.")
    else:
        yield prefix, tree


class Stream:
    """Tokens from the MLX thread to one HTTP response."""

    def __init__(self):
        self.id = "chatcmpl-" + uuid.uuid4().hex[:24]
        self.q: queue.Queue = queue.Queue()
        self.cancelled = False

    def put(self, text: str):
        if text:
            self.q.put(("text", text))

    def finish(self, reason: str, prompt_tokens: int, completion_tokens: int):
        self.q.put(("done", {"finish_reason": reason, "prompt_tokens": prompt_tokens,
                             "completion_tokens": completion_tokens}))

    def fail(self, message: str):
        self.q.put(("error", message))

    def __iter__(self):
        while True:
            kind, val = self.q.get()
            yield kind, val
            if kind in ("done", "error"):
                return
