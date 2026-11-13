# Pier

Turns a Mac into a private, OpenAI-compatible LLM server running MLX models on Apple silicon, and shows every Mac running Pier on the network as a topology.

- `engine/` – `pierd`, a Python daemon (MLX + mlx-lm). The HTTP API is on :52500.
  - `/v1/chat/completions` and `/v1/models` – OpenAI-compatible, streaming, open to the network
  - `/pier/*` – control API for the app (status, models, download, load). State-changing calls only work from this Mac.
  - Bonjour `_pier._tcp` discovery; the link to each peer is classified as Thunderbolt Bridge, Wi-Fi, Ethernet, or same Mac
- `app/` – SwiftUI app. It starts `pierd` if nothing is listening and stops it on quit.

## Install
Download `Pier-<version>.dmg` from [Releases](https://github.com/kalki-kgp/pier/releases) and drag Pier to Applications. It needs an Apple silicon Mac on macOS 26 and brings its own Python and MLX, so nothing else is needed.

Pier isn't notarized, so clear the download flag once before the first launch:
```sh
xattr -dr com.apple.quarantine /Applications/Pier.app
open /Applications/Pier.app
```

## Build from source
```sh
cd engine && uv venv --python 3.13 && uv pip install -r pyproject.toml
cd ../app && ./build.sh && open Pier.app
```
`app/release.sh` builds the self-contained app (bundled Python + engine) and `dist/Pier-<version>.dmg`.
Logs: `~/Library/Logs/Pier/pierd.log`.

Fake second node on the same Mac, for working on the canvas:
```sh
cd engine && PIER_PORT=52501 PIER_NAME="Mac mini (test)" PIER_NODE_ID=fake0000test .venv/bin/python -m pierd
```

Stop only the test node: `lsof -ti tcp:52501 -sTCP:LISTEN | xargs kill`

## Split mode (one model across Macs)
- This Mac becomes rank 0 and runs the last layers. It tells each peer (`/pier/cluster/join`) to run `pierd.shard` as a later rank. Ranks talk over mx.distributed's ring backend (TCP), on ports 52520+rank.
- Layers are split in proportion to each Mac's Metal budget (`cluster.plan_split`). `shard.sharded_load` replaces mlx-lm's loader so it can take that split and handle single-file checkpoints. Each Mac downloads only the shard files it needs.
- Rank 0 runs mlx-lm's server on 127.0.0.1:52510; pierd proxies `/v1` to it. Members answer `/v1` with 409.
- Only architectures whose mlx-lm module uses `PipelineMixin` can split. Detected live (`models.splittable`): Qwen2/2.5, Qwen3-MoE/3.5/Next, DeepSeek, GLM-4-MoE, Ministral/Mistral 4. Plain Qwen3, Llama and Gemma can't.
- Verified on one Mac with two ranks: greedy output is identical to the unsplit model.
- Not yet: pairing/auth between Macs. Any device that advertises `_pier._tcp` on the LAN counts as a peer. RDMA/jaccl for TB5 Macs. Per-request stats in split mode.
