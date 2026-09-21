# NVIDIA Nemotron 3 Ultra 550B A55B NVFP4 (Quads TP4, bounded 16K candidate)

| Field | Value |
| --- | --- |
| Profile | `nemotron-ultra-quads-vllm022-bounded16k` |
| Checkpoint | `nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-NVFP4` |
| Revision | `02462641f13d3af838b904f48195b9bb8a1e4ebc` |
| Runtime | `vllm 0.22.0` |
| DGX Sparks | 4 |
| Fabric | `switch` |
| Served context | `16384` |
| Qualification status | `qualified-quads-gb10-switched-vllm-0.22.0-tp4-bounded16k-functional-v1` |
| Upstream | https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-NVFP4 |

```bash
nix develop path:.#model-nemotron-ultra-quads-vllm022-bounded16k --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
