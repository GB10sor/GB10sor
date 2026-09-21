# OpenMed Privacy Filter Nemotron v2

| Field | Value |
| --- | --- |
| Profile | `privacy-filter` |
| Checkpoint | `OpenMed/privacy-filter-nemotron-v2` |
| Revision | `968247329d18998cc7d5338b941b52f1b2a9abd9` |
| Runtime | `transformers-token-classification 5.15.0` |
| DGX Sparks | 1 |
| Fabric | `solo` |
| Served context | `profile default` |
| Qualification status | `qualified-solo-gb10` |
| Upstream | https://huggingface.co/OpenMed/privacy-filter-nemotron-v2 |

```bash
nix develop path:.#model-privacy-filter --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
