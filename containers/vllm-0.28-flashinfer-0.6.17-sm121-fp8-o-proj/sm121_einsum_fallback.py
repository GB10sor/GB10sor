"""Correctness-first DeepSeek V4 FP8 output-projection fallback for SM121.

The vLLM 0.28 DeepSeek V4 attention path calls DeepGEMM's ``fp8_einsum``
unconditionally.  Its scale layout is not usable on consumer Blackwell
(SM120/SM121).  Dequantize both operands with their block scales and evaluate
the same einsum with PyTorch.  This is intentionally slower than a native
SM12x kernel, but keeps the workaround narrow and numerically inspectable.
"""

from __future__ import annotations

import torch


def _expand_block_scales(scales: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    expanded = scales.float()
    while expanded.dim() < target.dim():
        expanded = expanded.unsqueeze(-1)
    for dimension in range(target.dim()):
        if expanded.shape[dimension] != target.shape[dimension] and expanded.shape[dimension] > 1:
            repeats = -(-target.shape[dimension] // expanded.shape[dimension])
            expanded = expanded.repeat_interleave(repeats, dim=dimension)
        if expanded.shape[dimension] > target.shape[dimension]:
            expanded = expanded.narrow(dimension, 0, target.shape[dimension])
    return expanded


def fp8_einsum_torch(
    equation: str,
    activation_pair: tuple[torch.Tensor, torch.Tensor],
    weight_pair: tuple[torch.Tensor, torch.Tensor],
    output: torch.Tensor,
    recipe: tuple[int, int, int] | None = None,
    **_: object,
) -> torch.Tensor:
    """Evaluate ``bhr,hdr->bhd`` after exact scale expansion.

    E8M0 weight scales are exponent-only, so conversion to float32 is exact.
    ``recipe`` is accepted for API compatibility; the explicit block-scale
    expansion defines the fallback computation.
    """

    del recipe
    activation, activation_scale = activation_pair
    weight, weight_scale = weight_pair

    activation_float = activation.float()
    activation_float *= _expand_block_scales(activation_scale, activation_float)

    weight_float = weight.float()
    weight_float *= _expand_block_scales(weight_scale, weight_float)

    weight_subscripts = equation.split(",", 1)[1].split("->", 1)[0]
    if weight_float.dim() == 2 and len(weight_subscripts) == 3:
        weight_float = weight_float.view(
            output.shape[1], -1, weight_float.shape[-1]
        )

    output.copy_(torch.einsum(equation, activation_float, weight_float).to(output.dtype))
    return output
