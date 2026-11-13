"""One rank of a model split across Macs (pipeline parallel over mx.distributed).

Started by pierd with MLX_RANK, MLX_HOSTFILE (ring backend), PIER_SPLIT (layers per rank,
rank 0 first) and PIER_SHARD_PORT. Rank 0 serves mlx-lm's OpenAI server on 127.0.0.1;
pierd proxies /v1 to it. The other ranks follow rank 0's requests.

mlx-lm's own sharded_load splits layers evenly and needs model.safetensors.index.json;
this one takes the memory-weighted split and also handles single-file checkpoints.
"""

import json
import os
import re
import sys

import mlx.core as mx
from mlx_lm import server
from mlx_lm.utils import _download, load_model, load_tokenizer

META = ["*.json", "*.py", "tokenizer.model", "*.tiktoken", "tiktoken.model", "*.txt", "*.jsonl", "*.jinja"]


def sharded_load(repo, pipeline_group=None, tensor_group=None, return_config=False, *,
                 tokenizer_config=None, trust_remote_code=False):
    group = pipeline_group or mx.distributed.init()
    split = json.loads(os.environ["PIER_SPLIT"])
    model_path = _download(repo, allow_patterns=META)

    model, config = load_model(model_path, lazy=True, strict=False)
    if not (hasattr(model, "model") and hasattr(model.model, "pipeline")):
        raise ValueError(f"{config.get('model_type')} models can't be split across Macs yet")
    model.model.pipeline(group, split=split)
    start, end = model.model.start_idx, model.model.end_idx

    index = model_path / "model.safetensors.index.json"
    if index.exists():
        # Only fetch the files holding this rank's layers (plus embeddings / head).
        files = set()
        for key, f in json.loads(index.read_text())["weight_map"].items():
            m = re.search(r"(?:^|\.)layers\.(\d+)\.", key)
            if m is None or start <= int(m.group(1)) < end:
                files.add(f)
        _download(repo, allow_patterns=sorted(files))
    else:
        _download(repo, allow_patterns=["*.safetensors"])

    tokenizer = load_tokenizer(model_path, tokenizer_config or {"trust_remote_code": True},
                               eos_token_ids=config.get("eos_token_id", None))
    model, _ = load_model(model_path, lazy=True, strict=False)
    model.model.pipeline(group, split=split)
    mx.eval(model.parameters())
    print(f"rank {group.rank()}: layers {start}-{end - 1}, "
          f"{mx.get_active_memory() / 1e9:.2f} GB", file=sys.stderr, flush=True)
    mx.eval(mx.distributed.all_sum(mx.array(1.0), stream=mx.cpu))  # everyone loaded
    return (model, tokenizer, config) if return_config else (model, tokenizer)


def main():
    group = mx.distributed.init(backend="ring", strict=True)
    print(f"rank {group.rank()} of {group.size()} connected", file=sys.stderr, flush=True)
    server.sharded_load = sharded_load
    sys.argv = ["mlx_lm.server", "--model", os.environ["PIER_REPO"], "--pipeline",
                "--host", "127.0.0.1", "--port", os.environ.get("PIER_SHARD_PORT", "52510")]
    server.main()


if __name__ == "__main__":
    main()
