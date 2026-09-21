# NVIDIA DeepSeek V4.1 Flash NVFP4 (Eights TP8, SGLang da64c5c, candidate 16K)

| Field | Value |
| --- | --- |
| Profile | `nvidia-deepseek-v41-flash-nvfp4-eights-sglang-da64c5c-candidate16k` |
| Checkpoint | `nvidia/DeepSeek-V4.1-Flash-NVFP4` |
| Revision | `3431dde3247c13b5957f682b1e3c6fcae2566079` |
| Runtime | `sglang 0.0.0.dev1+gda64c5cbb` |
| DGX Sparks | 8 |
| Fabric | `switch` |
| Served context | `16384` |
| Qualification status | `qualified-eights-gb10-local-bounded16k-c1-lifecycle-v1` |
| Upstream | https://huggingface.co/nvidia/DeepSeek-V4.1-Flash-NVFP4/tree/3431dde3247c13b5957f682b1e3c6fcae2566079 |

```bash
nix develop path:.#model-nvidia-deepseek-v41-flash-nvfp4-eights-sglang-da64c5c-candidate16k --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
