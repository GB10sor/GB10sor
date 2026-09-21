# NVIDIA MiniMax-M3 NVFP4 (Quads TP4, 4 GiB KV/rank, bounded 16K functional qualification)

| Field | Value |
| --- | --- |
| Profile | `minimax-m3-nvfp4-quads-v028-bounded16k` |
| Checkpoint | `nvidia/MiniMax-M3-NVFP4` |
| Revision | `901464083161bf8612a29ff7ad29914cd4ab4a85` |
| Runtime | `vllm 0.28.0` |
| DGX Sparks | 4 |
| Fabric | `switch` |
| Served context | `16384` |
| Qualification status | `qualified-quads-gb10-switched-vllm-0.28.0-tp4-kv4g-bounded16k-functional-v1` |
| Upstream | https://huggingface.co/nvidia/MiniMax-M3-NVFP4 |

```bash
nix develop path:.#model-minimax-m3-nvfp4-quads-v028-bounded16k --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
