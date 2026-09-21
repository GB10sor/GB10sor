# NVIDIA DeepSeek V4 Flash 0731 NVFP4 (vLLM 0.28 SM121 combined fallback Deuces-direct)

| Field | Value |
| --- | --- |
| Profile | `deepseek-v4-flash-0731-nvidia-v028` |
| Checkpoint | `nvidia/DeepSeek-V4-Flash-0731-NVFP4` |
| Revision | `f1caa71142bd0be02f728c79f75042ac1e461579` |
| Runtime | `vllm 0.28.0` |
| DGX Sparks | 2 |
| Fabric | `direct` |
| Served context | `65536` |
| Qualification status | `qualified-deuces-gb10-direct-fresh-owner-v40` |
| Upstream | https://huggingface.co/nvidia/DeepSeek-V4-Flash-0731-NVFP4 |

```bash
nix develop path:.#model-deepseek-v4-flash-0731-nvidia-v028 --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
