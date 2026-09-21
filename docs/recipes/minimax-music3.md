# MiniMax Music 3

| Field | Value |
| --- | --- |
| Profile | `minimax-music3` |
| Checkpoint | `MiniMaxAI/MiniMax-Music3` |
| Revision | `fbdf52fbaaca799592917417eb05f1899f1255ec` |
| Runtime | `sglang-omni 0.1.3` |
| DGX Sparks | 1 |
| Fabric | `solo` |
| Served context | `profile default` |
| Qualification status | `qualified-solo-gb10` |
| Upstream | https://github.com/sgl-project/sglang-omni/blob/5207c5dbc45bd7fe8062bc9a222ea6121f990349/docs/cookbook/minimax_music3.md |

```bash
nix develop path:.#model-minimax-music3 --command ./scripts/launch-model.sh qualify-and-serve
```

The command does not download model weights. Stage the exact revision under `GB10_MODEL_ROOT` on every required node and provide the untracked lane configuration described in [cluster configuration](../configuration.md).
