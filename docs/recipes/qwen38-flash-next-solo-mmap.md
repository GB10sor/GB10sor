# RadixArk Qwen3.8 Flash-Next NVFP4 (pinned mmap Solo)

| Field | Value |
| --- | --- |
| Profile | `qwen38-flash-next-solo-mmap` |
| Checkpoint | `RadixArk/Qwen3.8-Flash-Next-NVFP4` |
| Revision | `7b719225242aacd3dbd3f9407468c2ee9a9d2594` |
| Runtime | `vllm 0.1.dev20073+g8e685d198` |
| DGX Sparks | 1 |
| Fabric | `solo` |
| Served context | `262144` |
| Qualification status | `qualified-solo-gb10-pinned-mmap` |
| Upstream | https://huggingface.co/RadixArk/Qwen3.8-Flash-Next-NVFP4 |

```bash
nix develop path:.#model-qwen38-flash-next-solo-mmap --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
