# NVIDIA Nemotron 3.5 Lightning 30B A3B NVFP4 (Atlas DSpark Solo)

| Field | Value |
| --- | --- |
| Profile | `nemotron-lightning-atlas-dspark` |
| Checkpoint | `nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4` |
| Revision | `e8f3c7c4de75ad84fe1bcef95d38eca76214480b` |
| Runtime | `atlas 1.0.0-beta-preview` |
| DGX Sparks | 1 |
| Fabric | `solo` |
| Served context | `32768` |
| Qualification status | `qualified-solo-gb10-bounded-v1` |
| Upstream | https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4 |

```bash
nix develop path:.#model-nemotron-lightning-atlas-dspark --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
