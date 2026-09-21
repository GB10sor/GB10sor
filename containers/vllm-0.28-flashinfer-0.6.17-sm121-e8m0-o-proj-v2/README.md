# vLLM 0.28 SM121 DeepSeek V4 combined fallback

This deterministic overlay combines two narrow, fail-closed GB10 fixes: the
reviewed FP32 output-projection fallback and vLLM's own exact E8M0-to-FP32
scale conversion for Triton's dense FP8 path. The base image is digest-pinned,
and the patch refuses any unexpected upstream or previously patched source.

This remains a qualification candidate until the exact pinned DeepSeek V4
Flash 0731 checkpoint passes the full Deuces-direct acceptance and hold.
