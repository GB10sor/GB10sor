# Kimi K3 QSRT K2 (Eights TP8, bounded 8K functional)

| Field | Value |
| --- | --- |
| Profile | `kimi-k3-eights-custom` |
| Checkpoint | `lukealonso/Kimi-K3-QSRT-K2` |
| Revision | `c0afd8f8f260d1225f3d0ef63aac3bc2682fc513` |
| Runtime | `vllm 0.11.2.dev280+infernal.de04f08.cu133.torch213` |
| DGX Sparks | 8 |
| Fabric | `switch` |
| Served context | `8192` |
| Qualification status | `qualified-eights-gb10-switched-custom-vllm-tp8-bounded8k-lifecycle-and-worker-loss-recovery-v2` |
| Upstream | https://huggingface.co/lukealonso/Kimi-K3-QSRT-K2 |

```bash
nix develop path:.#model-kimi-k3-eights-custom --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
