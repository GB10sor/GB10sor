# GLM-5.3 Flash NVFP4 target-only (SGLang single-primary Deuces-direct)

| Field | Value |
| --- | --- |
| Profile | `glm53-flash-nvfp4-sglang-target-only` |
| Checkpoint | `LibertAIDAI/GLM-5.3-Flash-NVFP4` |
| Revision | `357b45cc73a07a541cede88861f7736c9487ebf7` |
| Runtime | `sglang 0.0.0.dev1+g033446bb05` |
| DGX Sparks | 2 |
| Fabric | `direct` |
| Served context | `profile default` |
| Qualification status | `qualified-deuces-gb10-direct-fresh-owner-v37` |
| Upstream | https://huggingface.co/LibertAIDAI/GLM-5.3-Flash-NVFP4 |

```bash
nix develop path:.#model-glm53-flash-nvfp4-sglang-target-only --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
