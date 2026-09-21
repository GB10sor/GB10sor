# RadixArk Qwen3.8 27B NVFP4 BF16 LM Head

| Field | Value |
| --- | --- |
| Profile | `radixark-qwen38` |
| Checkpoint | `RadixArk/Qwen3.8-27B-NVFP4-BF16-LMHead` |
| Revision | `009632fef96dd349150baa780c984e62e70e91fe` |
| Runtime | `sglang 0.0.0.dev1+g5f55db35e` |
| DGX Sparks | 1 |
| Fabric | `solo` |
| Served context | `65536` |
| Qualification status | `qualified-solo-gb10` |
| Upstream | https://huggingface.co/RadixArk/Qwen3.8-27B-NVFP4-BF16-LMHead |

```bash
nix develop path:.#model-radixark-qwen38 --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
