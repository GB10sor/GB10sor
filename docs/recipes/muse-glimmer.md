# RedHatAI Muse Glimmer 30B NVFP4

| Field | Value |
| --- | --- |
| Profile | `muse-glimmer` |
| Checkpoint | `RedHatAI/Muse-Glimmer-30B-NVFP4` |
| Revision | `d5109a1d187c27bd1734e81844e71aa4d964e66a` |
| Runtime | `vllm 0.26.1rc1.dev608+g99a10304d` |
| DGX Sparks | 1 |
| Fabric | `solo` |
| Served context | `131072` |
| Qualification status | `qualified-solo-gb10` |
| Upstream | https://recipes.vllm.ai/meta-models/Muse-Glimmer-30B |

```bash
nix develop path:.#model-muse-glimmer --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
