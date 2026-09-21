# syntax=docker/dockerfile:1

ARG BASE_IMAGE=docker.io/lmsysorg/sglang@sha256:d4a984cdeb9846ef0d433d80e8fff55d527fa84f91c0eec2c62d9dea7ab26426
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG SGLANG_OMNI_COMMIT=5207c5dbc45bd7fe8062bc9a222ea6121f990349
ARG SGLANG_OMNI_SOURCE_TREE_SHA256=895093395dcf7a88574d49e64b594ed007b7d40324e0c42e994fdce53984fd21

LABEL org.opencontainers.image.title="GB10sor SGLang-Omni ARM64 runtime" \
      org.opencontainers.image.source="https://github.com/sgl-project/sglang-omni" \
      org.opencontainers.image.revision="${SGLANG_OMNI_COMMIT}" \
      ai.gb10sor.base-image="${BASE_IMAGE}" \
      ai.gb10sor.source-tree-sha256="${SGLANG_OMNI_SOURCE_TREE_SHA256}"

COPY . /opt/sglang-omni-source

# The pinned ARM64 SGLang 0.5.16 base already contains the exact CUDA 13,
# PyTorch 2.11, Transformers 5.12.1, FlashInfer 0.6.14, and cache-dit 1.3.0
# stack required by this source revision. Refuse dependency resolution here so
# an upstream index change cannot silently replace the qualified GPU stack.
RUN cp -a /opt/sglang-omni-source /tmp/sglang-omni-build \
    && python3 -m pip install \
      --no-deps \
      --no-build-isolation \
      /tmp/sglang-omni-build \
    && rm -rf /tmp/sglang-omni-build \
    && sgl-omni --help >/dev/null \
    && python3 -c 'from sglang_omni.models.minimax_music3.config import MiniMaxMusic3SingleGPUPipelineConfig; print("music3_import=pass")'

ENTRYPOINT ["/opt/nvidia/nvidia_entrypoint.sh"]
CMD ["/bin/bash"]
