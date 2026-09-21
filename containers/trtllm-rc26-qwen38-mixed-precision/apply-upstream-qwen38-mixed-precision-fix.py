#!/usr/bin/env python3
"""Backport NVIDIA/TensorRT-LLM#18823 onto the exact 1.3.0rc26 image."""

from __future__ import annotations

import hashlib
from pathlib import Path


ROOT = Path("/usr/local/lib/python3.12/dist-packages/tensorrt_llm/_torch")
PLE = ROOT / "modules/qwen4_exp/ple.py"
MODEL = ROOT / "models/modeling_qwen4_exp.py"

EXPECTED_INPUTS = {
    PLE: "dc7f68af33b7f3772da2b41afcc091388359d5c3c5db5a6ea323bd3dfe6c433a",
    MODEL: "d23bb044f07082dc86743c1378f84f077c485a55c77e9aba5909cadee6185c28",
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source match, found {count}")
    return text.replace(old, new, 1)


for source, expected in EXPECTED_INPUTS.items():
    observed = digest(source)
    if observed != expected:
        raise RuntimeError(
            f"refusing to patch changed TensorRT-LLM source {source}: "
            f"expected {expected}, observed {observed}"
        )

ple = PLE.read_text()
ple = replace_once(
    ple,
    "from tensorrt_llm.mapping import Mapping\n",
    "from tensorrt_llm.mapping import Mapping\n"
    "from tensorrt_llm.quantization.mode import QuantAlgo\n"
    "from tensorrt_llm.quantization.modelopt_config import canonicalize_quant_algo\n",
    "PLE quantization imports",
)
ple = replace_once(
    ple,
    '_PLE_HOST_OFFLOAD_ENV = "TRTLLM_QWEN4_EXP_PLE_HOST_OFFLOAD"\n',
    '_PLE_HOST_OFFLOAD_ENV = "TRTLLM_QWEN4_EXP_PLE_HOST_OFFLOAD"\n'
    '# Substring both quantization schemas use to name the PLE n-gram table.\n'
    '_NGRAM_TABLE_MARKER = "ple.ple_embedding.ngram_embedding"\n',
    "PLE table marker",
)
ple = replace_once(
    ple,
    '''def _uses_scaled_fp8_ngram_table(config: object) -> bool:
    """Return whether the HF config declares the custom scaled-FP8 PLE table."""
    quantization_config = getattr(config, "quantization_config", None)
    if not isinstance(quantization_config, dict):
        return False
    if quantization_config.get("quant_method") != "fp8":
        return False
    excluded = quantization_config.get("modules_to_not_convert") or ()
    if isinstance(excluded, str):
        excluded = (excluded,)
    marker = "ple.ple_embedding.ngram_embedding"
    return not any(marker in module_name for module_name in excluded)
''',
    '''def _uses_scaled_fp8_ngram_table(config: object) -> bool:
    """Return whether the HF config declares the custom scaled-FP8 PLE table."""
    quantization_config = getattr(config, "quantization_config", None)
    if not isinstance(quantization_config, dict):
        return False

    quantized = quantization_config.get("quantized_layers")
    if isinstance(quantized, dict):
        return any(
            _NGRAM_TABLE_MARKER in name
            and canonicalize_quant_algo(spec.get("quant_algo")) == QuantAlgo.FP8
            for name, spec in quantized.items()
        )

    if quantization_config.get("quant_method") != "fp8":
        return False
    skipped = quantization_config.get("modules_to_not_convert") or ()
    if isinstance(skipped, str):
        skipped = (skipped,)
    return not any(_NGRAM_TABLE_MARKER in name for name in skipped)
''',
    "PLE mixed-precision detector",
)
PLE.write_text(ple)

model = MODEL.read_text()
model = replace_once(
    model,
    "from .modeling_qwen3_5 import _normalize_qwen35_exclude_modules\n",
    "from .modeling_qwen3_5 import (\n"
    "    _normalize_qwen35_exclude_modules,\n"
    "    _normalize_qwen35_quant_config_dict,\n"
    ")\n",
    "Qwen3.5 normalization imports",
)
model = replace_once(
    model,
    "        _normalize_qwen35_exclude_modules(model_config)\n"
    "        spec_config = getattr(model_config, \"spec_config\", None)\n",
    "        _normalize_qwen35_exclude_modules(model_config)\n"
    "        _normalize_qwen35_quant_config_dict(model_config)\n"
    "        spec_config = getattr(model_config, \"spec_config\", None)\n",
    "Qwen4Exp quantization normalization call",
)
MODEL.write_text(model)

# Structural postconditions make accidental partial patches fail the build.
patched_ple = PLE.read_text()
patched_model = MODEL.read_text()
assert 'quantization_config.get("quantized_layers")' in patched_ple
assert "canonicalize_quant_algo" in patched_ple
assert "_normalize_qwen35_quant_config_dict(model_config)" in patched_model
print(f"patched_ple_sha256={digest(PLE)}")
print(f"patched_model_sha256={digest(MODEL)}")

