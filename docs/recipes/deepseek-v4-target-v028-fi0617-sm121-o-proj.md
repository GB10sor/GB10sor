# NVIDIA DeepSeek V4 Flash NVFP4 target-only (vLLM 0.28, FlashInfer 0.6.17, SM121 fallbacks)

| Field | Value |
| --- | --- |
| Profile | `deepseek-v4-target-v028-fi0617-sm121-o-proj` |
| Checkpoint | `nvidia/DeepSeek-V4-Flash-nvfp4-DSpark` |
| Revision | `7ac53121c19350518c374b67e3883ceb189fb26e` |
| Runtime | `vllm 0.28.0` |
| DGX Sparks | 2 |
| Fabric | `switch` |
| Served context | `profile default` |
| Qualification status | `qualified-deuces-gb10-switched-vllm-0.28.0-sm121-correctness-fallbacks` |
| Upstream | https://huggingface.co/nvidia/DeepSeek-V4-Flash-nvfp4-DSpark |

```bash
nix develop path:.#model-deepseek-v4-target-v028-fi0617-sm121-o-proj --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
