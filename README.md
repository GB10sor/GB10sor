# GB10SOR

Reproducible, one-command model deployments for NVIDIA DGX Spark. The standard edition omits the restricted checkpoint set.

Every listed profile has a pinned checkpoint revision, runtime image, launch arguments, topology launcher, and a `nix develop` shell. Development shells never download a checkpoint or start a service automatically.

Setting up a new machine? Start with the [DGX Spark quickstart](QUICKSTART.md), including the tested NixOS USB path.

## Start

```bash
git clone https://github.com/GB10sor/GB10sor.git
cd GB10sor
nix develop path:.#model-PROFILE --command ./scripts/launch-model.sh qualify-and-serve
```

Replace `PROFILE` with a linked profile below. Multi-Spark lanes also require the private local configuration described in [configuration](docs/configuration.md). Checkpoints stay outside Git and retain their own licenses.

## Models by DGX Spark count

### Solo — 1 DGX Spark

| Model | Runtime | Fabric | Source |
| --- | --- | --- | --- |
| MiniMaxAI/MiniMax-Music3 | sglang-omni | solo | [Open recipe](docs/recipes/minimax-music3.md) |
| RedHatAI/Muse-Glimmer-30B-NVFP4 | vllm | solo | [Open recipe](docs/recipes/muse-glimmer.md) |
| nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4 | vllm | solo | [Open recipe](docs/recipes/nemotron-lightning.md) |
| nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4 | atlas | solo | [Open recipe](docs/recipes/nemotron-lightning-atlas-dspark.md) |
| nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4 | trtllm | solo | [Open recipe](docs/recipes/nemotron-lightning-trtllm-rc26.md) |
| OpenMed/privacy-filter-nemotron-v2 | transformers-token-classification | solo | [Open recipe](docs/recipes/privacy-filter.md) |
| nvidia/Qwen3.8-Flash-Next-NVFP4 | vllm | solo | [Open recipe](docs/recipes/qwen38-flash-next-nvidia-solo-vllm.md) |
| RadixArk/Qwen3.8-Flash-Next-NVFP4 | vllm | solo | [Open recipe](docs/recipes/qwen38-flash-next-solo-mmap.md) |
| RadixArk/Qwen3.8-27B-NVFP4-BF16-LMHead | sglang | solo | [Open recipe](docs/recipes/radixark-qwen38.md) |

### Deuces — 2 DGX Sparks

| Model | Runtime | Fabric | Source |
| --- | --- | --- | --- |
| nvidia/DeepSeek-V4-Flash-0731-NVFP4 | vllm | direct | [Open recipe](docs/recipes/deepseek-v4-flash-0731-nvidia-v028.md) |
| nvidia/DeepSeek-V4-Flash-nvfp4-DSpark | vllm | direct | [Open recipe](docs/recipes/deepseek-v4-nvidia-anemll-vllm.md) |
| nvidia/DeepSeek-V4-Flash-nvfp4-DSpark | sglang | switch | [Open recipe](docs/recipes/deepseek-v4-sglang-target-only.md) |
| nvidia/DeepSeek-V4-Flash-nvfp4-DSpark | vllm | switch | [Open recipe](docs/recipes/deepseek-v4-target-v028-fi0617-sm121-o-proj.md) |
| Mia-AiLab/DeepSeek-V4.1-Flash-EXL3-2.9bpw | vllm | direct | [Open recipe](docs/recipes/deepseek-v41-flash-exl3-29bpw.md) |
| LibertAIDAI/GLM-5.3-Flash-NVFP4 | sglang | direct | [Open recipe](docs/recipes/glm53-flash-nvfp4-sglang-dflash2.md) |
| LibertAIDAI/GLM-5.3-Flash-NVFP4 | sglang | direct | [Open recipe](docs/recipes/glm53-flash-nvfp4-sglang-target-only.md) |
| thinkingmachines/Inkling-Small-NVFP4 | sglang | direct | [Open recipe](docs/recipes/inkling-small-nvfp4-sglang-dspark.md) |
| poolside/Laguna-S-2.1-NVFP4 | vllm | direct | [Open recipe](docs/recipes/laguna-s21-nvfp4.md) |
| RadixArk/Qwen3.8-Flash-Next-NVFP4 | sglang | switch | [Open recipe](docs/recipes/qwen38-flash-next.md) |
| RadixArk/Qwen3.8-Flash-Next-NVFP4 | sglang | direct | [Open recipe](docs/recipes/qwen38-flash-next-direct-bounded.md) |
| nvidia/Qwen3.8-Flash-Next-NVFP4 | vllm | direct | [Open recipe](docs/recipes/qwen38-flash-next-nvidia-vllm.md) |

### Trips — 3 DGX Sparks

No eligible profiles in this edition.

### Quads — 4 DGX Sparks

| Model | Runtime | Fabric | Source |
| --- | --- | --- | --- |
| nvidia/MiniMax-M3-NVFP4 | vllm | switch | [Open recipe](docs/recipes/minimax-m3-nvfp4-quads-v028-bounded16k.md) |
| nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-NVFP4 | vllm | switch | [Open recipe](docs/recipes/nemotron-ultra-quads-vllm022-bounded16k.md) |
| nvidia/GLM-5.3-Flash-NVFP4 | vllm | switch | [Open recipe](docs/recipes/nvidia-glm53-flash-nvfp4-quads-vllm0281-bounded32k.md) |

### Eights — 8 DGX Sparks

| Model | Runtime | Fabric | Source |
| --- | --- | --- | --- |
| incoai/GLM-5.3-NVFP4 | sglang | switch | [Open recipe](docs/recipes/glm53-nvfp4-eights-sglang0519-bounded16k.md) |
| lukealonso/Kimi-K3-QSRT-K2 | vllm | switch | [Open recipe](docs/recipes/kimi-k3-eights-custom.md) |
| nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-NVFP4 | vllm | switch | [Open recipe](docs/recipes/nemotron-ultra-eights-vllm022.md) |
| nvidia/DeepSeek-V4.1-Flash-NVFP4 | sglang | switch | [Open recipe](docs/recipes/nvidia-deepseek-v41-flash-nvfp4-eights-sglang-da64c5c-candidate16k.md) |

## Repository map

- `flake.nix` creates one shell for every profile.
- `model-profiles.json` is the runtime registry.
- `scripts/launch-model.sh` dispatches the same command to the correct topology launcher.
- `benchmark-profiles/` and `benchmark-recipes/` hold bounded test inputs.
- `VERIFY.command` checks the registry, source inventory, checksums, and publication-safety rules.

## Security

Read the [operational security guide](docs/security.md), or [report a vulnerability privately](SECURITY.md). This is community maintained and is not an NVIDIA product.

## License

Original repository code is Apache-2.0. Models, images, and external runtimes keep their own terms; see [third-party notices](THIRD_PARTY_NOTICES.md).
