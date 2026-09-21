# Thinking Machines Inkling Small NVFP4 (patched SGLang DSpark candidate)

| Field | Value |
| --- | --- |
| Profile | `inkling-small-nvfp4-sglang-dspark` |
| Checkpoint | `thinkingmachines/Inkling-Small-NVFP4` |
| Revision | `b6a99534467840620d411e4cd4ad5819b2610d9c` |
| Runtime | `sglang 0.0.0.dev1+gb7252cc6b` |
| DGX Sparks | 2 |
| Fabric | `direct` |
| Served context | `profile default` |
| Qualification status | `qualified-deuces-gb10-direct-fresh-owner-v38` |
| Upstream | https://huggingface.co/thinkingmachines/Inkling-Small-NVFP4 |

```bash
nix develop path:.#model-inkling-small-nvfp4-sglang-dspark --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
