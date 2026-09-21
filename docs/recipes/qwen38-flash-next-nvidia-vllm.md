# NVIDIA Qwen3.8 Flash-Next NVFP4 (vLLM Deuces-direct speed profile)

| Field | Value |
| --- | --- |
| Profile | `qwen38-flash-next-nvidia-vllm` |
| Checkpoint | `nvidia/Qwen3.8-Flash-Next-NVFP4` |
| Revision | `fab0aecb760cec45227f6656abcaafa11abca87a` |
| Runtime | `vllm 0.28.1rc1.dev388+g8a728663c` |
| DGX Sparks | 2 |
| Fabric | `direct` |
| Served context | `262144` |
| Qualification status | `qualified-deuces-gb10-direct-fresh-owner-v42` |
| Upstream | https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4 |

```bash
nix develop path:.#model-qwen38-flash-next-nvidia-vllm --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
