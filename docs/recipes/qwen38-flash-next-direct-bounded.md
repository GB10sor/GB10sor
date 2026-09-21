# RadixArk Qwen3.8 Flash-Next NVFP4 (bounded Deuces direct)

| Field | Value |
| --- | --- |
| Profile | `qwen38-flash-next-direct-bounded` |
| Checkpoint | `RadixArk/Qwen3.8-Flash-Next-NVFP4` |
| Revision | `7b719225242aacd3dbd3f9407468c2ee9a9d2594` |
| Runtime | `sglang 0.0.0.dev1+gd91c3682b` |
| DGX Sparks | 2 |
| Fabric | `direct` |
| Served context | `65536` |
| Qualification status | `qualified-deuces-gb10-direct-bounded-functional` |
| Upstream | https://huggingface.co/RadixArk/Qwen3.8-Flash-Next-NVFP4 |

```bash
nix develop path:.#model-qwen38-flash-next-direct-bounded --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
