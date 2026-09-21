# MiaAI DeepSeek V4.1 Flash EXL3 2.9 bpw (Deuces-direct TP2 qualified)

| Field | Value |
| --- | --- |
| Profile | `deepseek-v41-flash-exl3-29bpw` |
| Checkpoint | `Mia-AiLab/DeepSeek-V4.1-Flash-EXL3-2.9bpw` |
| Revision | `64ba41b6c916a587db06eae2e19b7845f7be6e6b` |
| Runtime | `vllm 0.1.dev20904+g179dd0fa9` |
| DGX Sparks | 2 |
| Fabric | `direct` |
| Served context | `600000` |
| Qualification status | `qualified-deuces-direct-tp2-600k-cleanup-v1` |
| Upstream | https://huggingface.co/Mia-AiLab/DeepSeek-V4.1-Flash-EXL3-2.9bpw/tree/64ba41b6c916a587db06eae2e19b7845f7be6e6b |

```bash
nix develop path:.#model-deepseek-v41-flash-exl3-29bpw --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
