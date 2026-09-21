# NVIDIA DeepSeek V4 Flash NVFP4 (Anemll vLLM Deuces-direct bounded qualification)

| Field | Value |
| --- | --- |
| Profile | `deepseek-v4-nvidia-anemll-vllm` |
| Checkpoint | `nvidia/DeepSeek-V4-Flash-nvfp4-DSpark` |
| Revision | `7ac53121c19350518c374b67e3883ceb189fb26e` |
| Runtime | `vllm 0.25.2.dev0+g752a3a504.d20260714` |
| DGX Sparks | 2 |
| Fabric | `direct` |
| Served context | `profile default` |
| Qualification status | `qualified-deuces-gb10-direct-bounded32k-no-speculation-v1` |
| Upstream | https://huggingface.co/nvidia/DeepSeek-V4-Flash-nvfp4-DSpark |

```bash
nix develop path:.#model-deepseek-v4-nvidia-anemll-vllm --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
