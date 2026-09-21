# Poolside Laguna S 2.1 NVFP4 with DFlash

| Field | Value |
| --- | --- |
| Profile | `laguna-s21-nvfp4` |
| Checkpoint | `poolside/Laguna-S-2.1-NVFP4` |
| Revision | `64734b3a449a05c79657451513d97544f2f53436` |
| Runtime | `vllm 0.27.1` |
| DGX Sparks | 2 |
| Fabric | `direct` |
| Served context | `profile default` |
| Qualification status | `qualified-deuces-gb10-direct-fresh-owner-v38` |
| Upstream | https://huggingface.co/poolside/Laguna-S-2.1-NVFP4 |

```bash
nix develop path:.#model-laguna-s21-nvfp4 --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
