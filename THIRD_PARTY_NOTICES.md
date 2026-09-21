# Third-party notices

Model checkpoints and container images are referenced but never redistributed by this repository. They retain their own licenses, acceptable-use policies, and terms.

| Dependency | Immutable identity | Treatment |
| --- | --- | --- |
| Nixpkgs | `c25784012c9982bca5b3e0de87e90bbdac8927d3` | External flake input |
| SGLang-Omni | `5207c5dbc45bd7fe8062bc9a222ea6121f990349` | External source input for the reviewed Music3 runtime build |
| [graham33/nixos-dgx-spark](https://github.com/graham33/nixos-dgx-spark) | Upstream `main` documentation | DGX Spark NixOS installation and compatibility reference; not vendored |
| vLLM, SGLang, TensorRT-LLM, and Atlas | Per-profile image identity in `model-profiles.json` | External runtime image; not redistributed |
| Model checkpoints | Per-profile repository and revision in `model-profiles.json` | Downloaded separately by the operator; not redistributed |

An immutable revision or digest identifies bytes. It does not replace license, security, provenance, export-control, or model-policy review by the operator.
