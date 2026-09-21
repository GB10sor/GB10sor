# NVIDIA GLM-5.3 Flash NVFP4 (Quads TP4+EP, qualified bounded 32K)

| Field | Value |
| --- | --- |
| Profile | `nvidia-glm53-flash-nvfp4-quads-vllm0281-bounded32k` |
| Checkpoint | `nvidia/GLM-5.3-Flash-NVFP4` |
| Revision | `423acf37583782c51c142d145aef733d72943d93` |
| Runtime | `vllm 0.28.1rc1.dev580+g385dce36b` |
| DGX Sparks | 4 |
| Fabric | `switch` |
| Served context | `32768` |
| Qualification status | `qualified-quads-gb10-switched-vllm-0.28.1-pr53969-tp4-ep-bounded32k-functional-stress-cleanup-worker-loss-recovery-v2-and-1800s-soak-v3` |
| Upstream | https://huggingface.co/nvidia/GLM-5.3-Flash-NVFP4 |

```bash
nix develop path:.#model-nvidia-glm53-flash-nvfp4-quads-vllm0281-bounded32k --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
