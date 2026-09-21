# incoai GLM-5.3 NVFP4 (Eights TP8, SGLang 0.5.19 bounded 16K functional)

| Field | Value |
| --- | --- |
| Profile | `glm53-nvfp4-eights-sglang0519-bounded16k` |
| Checkpoint | `incoai/GLM-5.3-NVFP4` |
| Revision | `54e52520606f96b3d9fc84088ad22882a61648ac` |
| Runtime | `sglang 0.5.19` |
| DGX Sparks | 8 |
| Fabric | `switch` |
| Served context | `16384` |
| Qualification status | `qualified-eights-gb10-switched-sglang-0.5.19-tp8-bounded16k-lifecycle-v1` |
| Upstream | https://huggingface.co/incoai/GLM-5.3-NVFP4 |

```bash
nix develop path:.#model-glm53-nvfp4-eights-sglang0519-bounded16k --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
