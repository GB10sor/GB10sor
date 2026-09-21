"""Teach the vLLM Triton block-FP8 path to consume UE8M0 weight scales.

The NVIDIA DeepSeek V4 checkpoint stores 128x128 FP8 weight scales as
``float8_e8m0fnu``.  Triton's argument binder cannot accept that dtype, while
vLLM's other SM12x kernel already converts the same representation with
``_upcast_e8m0_to_fp32``.  Apply that existing conversion immediately before
the Triton custom op and refuse to patch an unexpected upstream source.
"""

from pathlib import Path


PATH = Path(
    "/usr/local/lib/python3.12/dist-packages/vllm/model_executor/"
    "kernels/linear/scaled_mm/triton.py"
)

OLD = """        return torch.ops.vllm.w8a8_triton_block_scaled_mm_func(
            A,
            B,
            As,
            Bs,
            list(self.weight_group_shape),
            self.config.out_dtype,
        )
"""

NEW = """        if Bs.dtype in (torch.float8_e8m0fnu, torch.uint8):
            from vllm.model_executor.layers.quantization.utils.fp8_utils import (
                _upcast_e8m0_to_fp32,
            )

            Bs = _upcast_e8m0_to_fp32(Bs).contiguous()
        return torch.ops.vllm.w8a8_triton_block_scaled_mm_func(
            A,
            B,
            As,
            Bs,
            list(self.weight_group_shape),
            self.config.out_dtype,
        )
"""

source = PATH.read_text()
if source.count(OLD) != 1:
    raise RuntimeError("unexpected vLLM Triton source; refusing an ambiguous patch")
PATH.write_text(source.replace(OLD, NEW))

