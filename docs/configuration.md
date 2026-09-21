# Cluster configuration

Solo profiles use `GB10_MODEL_ROOT`, defaulting to `$HOME/.local/share/gb10sor/models`.

Multi-Spark launchers read private, untracked configuration from `$HOME/.config/gb10sor/`:

| Lane | Default file | Override |
| --- | --- | --- |
| Deuces direct | `deuces-direct.json` and `deuces-direct.env` | `GB10_DEUCES_DIRECT_PROVISION`, `GB10_DEUCES_DIRECT_CONFIG` |
| Deuces switch | `deuces-switch.env` | `GB10_DEUCES_SWITCH_CONFIG` |
| Trips switch | `trips-switch.env` | `GB10_TRIPS_SWITCH_CONFIG` |
| Quads switch | `quads-switch.env` | `GB10_QUADS_SWITCH_CONFIG` |
| Eights switch | `eights-switch.env` | `GB10_EIGHTS_SWITCH_CONFIG` |

Never commit these files. They contain host bindings, private addresses, SSH identity paths, local image identities, and storage paths. Keep endpoints on loopback and use SSH or an authenticated private overlay for access.

Run the recipe's `show` action before deployment:

```bash
nix develop path:.#model-PROFILE --command ./scripts/launch-model.sh show
```
