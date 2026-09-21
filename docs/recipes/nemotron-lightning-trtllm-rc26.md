# NVIDIA Nemotron 3.5 Lightning 30B A3B NVFP4 (TensorRT-LLM rc26 bounded Solo)

| Field | Value |
| --- | --- |
| Profile | `nemotron-lightning-trtllm-rc26` |
| Checkpoint | `nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4` |
| Revision | `e8f3c7c4de75ad84fe1bcef95d38eca76214480b` |
| Runtime | `trtllm 1.3.0rc26` |
| DGX Sparks | 1 |
| Fabric | `solo` |
| Served context | `profile default` |
| Qualification status | `qualified-solo-gb10-trtllm-rc26-functional` |
| Upstream | https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4 |

```bash
nix develop path:.#model-nemotron-lightning-trtllm-rc26 --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
