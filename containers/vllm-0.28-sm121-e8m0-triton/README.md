# vLLM 0.28 SM121 UE8M0 Triton compatibility layer

This candidate derives from the locally pinned vLLM 0.28 image used by the
exact NVIDIA DeepSeek V4 Flash 0731 profile. It makes one fail-closed source
change: weight-scale tensors stored as FP8 UE8M0 are converted with vLLM's own
`_upcast_e8m0_to_fp32` helper immediately before the Triton block-FP8 custom
operation. No model file is modified.

Build with a fixed timestamp so both Deuces nodes produce the same OCI image
identity:

```text
podman build --pull=never --layers=false --timestamp=0 \
  -t localhost/gb10sor/vllm-deepseek-v028-e8m0-triton:candidate .
```

The image remains a candidate until the exact checkpoint passes the endpoint,
correctness, structured-output, streaming, stress, hold, and cleanup gates on
both GB10 nodes.
