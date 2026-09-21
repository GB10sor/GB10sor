#!/usr/bin/env python3
"""Credential-free NVFP4/GB10 hardware smoke workload.

The caller supplies the container image and evidence location.  This workload
uses only seeded synthetic tensors; it neither downloads nor opens a model.
"""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import math
import os
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path


def emit(document: dict[str, object], exit_code: int) -> None:
    payload = json.dumps(document, separators=(",", ":"), sort_keys=True)
    destination = os.environ.get("GB10_EVIDENCE_PATH", "")
    if destination:
        target = Path(destination)
        temporary = target.with_name(f".{target.name}.tmp")
        temporary.write_text(payload + "\n", encoding="utf-8")
        os.replace(temporary, target)
    print(payload, flush=True)
    raise SystemExit(exit_code)


started = time.perf_counter()
evidence: dict[str, object] = {
    "schema_version": 1,
    "test": "nvfp4-synthetic-native-gemm",
    "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
}

try:
    import torch
    import torch.nn.functional as functional

    import modelopt
    import modelopt.torch.quantization as mtq
    from modelopt.torch.quantization.nn.modules.quant_linear import RealQuantLinear
    from modelopt.torch.quantization.qtensor import NVFP4QTensor, QTensorWrapper

    if not torch.cuda.is_available():
        raise RuntimeError("torch.cuda.is_available() is false")

    device_index = int(os.environ.get("GB10_CUDA_DEVICE", "0"))
    if device_index < 0 or device_index >= torch.cuda.device_count():
        raise RuntimeError(
            f"CUDA device index {device_index} is outside 0..{torch.cuda.device_count() - 1}"
        )

    torch.cuda.set_device(device_index)
    device = torch.device("cuda", device_index)
    properties = torch.cuda.get_device_properties(device_index)
    capability = tuple(torch.cuda.get_device_capability(device_index))
    device_name = properties.name

    assertions: dict[str, bool] = {
        "compute_capability_12_1": capability == (12, 1),
        "cuda_available": True,
        "device_name_contains_gb10": "GB10" in device_name.upper(),
    }
    if not assertions["device_name_contains_gb10"]:
        raise RuntimeError(f"expected a GB10 GPU, found {device_name!r}")
    if not assertions["compute_capability_12_1"]:
        raise RuntimeError(
            f"expected GB10 compute capability 12.1, found {capability[0]}.{capability[1]}"
        )

    seed = 20260824
    batch_size = 16
    input_features = 256
    hidden_features = 256
    output_features = 128
    iterations = 20
    dtype = torch.float16

    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    generator = torch.Generator(device=device)
    generator.manual_seed(seed)

    model = torch.nn.Sequential(
        torch.nn.Linear(input_features, hidden_features, bias=False),
        torch.nn.GELU(),
        torch.nn.Linear(hidden_features, output_features, bias=False),
    ).to(device=device, dtype=dtype)
    model.eval()

    calibration_batches = [
        torch.randn(
            batch_size,
            input_features,
            device=device,
            dtype=dtype,
            generator=generator,
        )
        for _ in range(4)
    ]
    probe = torch.randn(
        batch_size,
        input_features,
        device=device,
        dtype=dtype,
        generator=generator,
    )

    with torch.inference_mode():
        reference = model(probe).float()

    original_weight_bytes = sum(
        parameter.numel() * parameter.element_size() for parameter in model.parameters()
    )

    def calibrate(candidate: torch.nn.Module) -> None:
        with torch.inference_mode():
            for batch in calibration_batches:
                candidate(batch)

    mtq.quantize(model, mtq.NVFP4_DEFAULT_CFG, calibrate)

    # ModelOpt 0.46.0's NVFP4 backend matcher compares the default config's
    # autoquant-only ``effective_bits`` metadata with the runtime quantizers,
    # but the quantizers do not expose that field. Preserve the published
    # numeric value so the matcher can select the native backend; this field
    # does not alter quantization scales, packing, or arithmetic.
    effective_bits_shim_count = 0
    for module in model.modules():
        for quantizer_attribute in ("input_quantizer", "weight_quantizer"):
            quantizer = getattr(module, quantizer_attribute, None)
            if quantizer is not None and not hasattr(quantizer, "effective_bits"):
                setattr(quantizer, "effective_bits", 4.5)
                effective_bits_shim_count += 1

    mtq.compress(model)

    with torch.inference_mode():
        output = model(probe).float()
        torch.cuda.synchronize(device)

        benchmark_started = time.perf_counter()
        for _ in range(iterations):
            model(probe)
        torch.cuda.synchronize(device)
        benchmark_seconds = time.perf_counter() - benchmark_started

    real_layers = [module for module in model.modules() if isinstance(module, RealQuantLinear)]
    compressed_layers = [
        module
        for module in real_layers
        if isinstance(getattr(module, "weight", None), QTensorWrapper)
    ]

    backend_diagnostics: dict[str, object] = {}
    try:
        import tensorrt_llm  # noqa: F401
        from modelopt.torch.quantization.backends.utils import fp4_compatible

        backend_diagnostics["fp4_compatible"] = bool(fp4_compatible())
        backend_diagnostics["tensorrt_llm_importable"] = True
        backend_diagnostics["tensorrt_llm_version"] = importlib.metadata.version(
            "tensorrt-llm"
        )
    except Exception as backend_error:
        backend_diagnostics["backend_import_error"] = str(backend_error)
        backend_diagnostics["tensorrt_llm_importable"] = False

    quant_cfg_list: list = mtq.NVFP4_DEFAULT_CFG["quant_cfg"]
    expected_quantizers = {
        "input": mtq.config.find_quant_cfg_entry_by_path(
            quant_cfg_list, "*input_quantizer"
        ).get("cfg", {}),
        "weight": mtq.config.find_quant_cfg_entry_by_path(
            quant_cfg_list, "*weight_quantizer"
        ).get("cfg", {}),
    }
    for quantizer_name, expected in list(expected_quantizers.items()):
        if isinstance(expected, list):
            expected_quantizers[quantizer_name] = expected[0]
    quantizer_mismatches: list[dict[str, str]] = []
    for layer_index, module in enumerate(real_layers):
        for quantizer_name, expected in expected_quantizers.items():
            quantizer = getattr(module, f"{quantizer_name}_quantizer")
            if not isinstance(expected, dict):
                quantizer_mismatches.append(
                    {
                        "actual": repr(type(quantizer)),
                        "expected": repr(expected),
                        "field": "configuration",
                        "layer": str(layer_index),
                        "quantizer": quantizer_name,
                    }
                )
                continue
            for key, expected_value in expected.items():
                if key == "enable":
                    continue
                actual_value = getattr(quantizer, key, "<missing>")
                if actual_value != expected_value:
                    quantizer_mismatches.append(
                        {
                            "actual": repr(actual_value),
                            "expected": repr(expected_value),
                            "field": key,
                            "layer": str(layer_index),
                            "quantizer": quantizer_name,
                        }
                    )
    backend_diagnostics["quantizer_mismatches"] = quantizer_mismatches

    packed_weight_bytes = 0
    packed_types: list[str] = []
    kernel_implementations: list[str] = []
    native_backend_selected = True
    for module in compressed_layers:
        qtensor = module.weight.get_qtensor()
        packed_types.append(type(qtensor).__name__)
        if not isinstance(qtensor, NVFP4QTensor):
            native_backend_selected = False
            continue
        packed = qtensor._quantized_data
        packed_weight_bytes += packed.numel() * packed.element_size()

        implementation = getattr(module, "_real_quant_gemm_impl", None)
        implementation_name = ""
        if implementation is not None:
            implementation_name = (
                f"{getattr(implementation, '__module__', '')}."
                f"{getattr(implementation, '__qualname__', '')}"
            )
        kernel_implementations.append(implementation_name)
        native_backend_selected = native_backend_selected and (
            "nvfp4_gemm" in implementation_name and "Nvfp4Linear" in implementation_name
        )

    cosine_similarity = float(
        functional.cosine_similarity(reference.flatten(), output.flatten(), dim=0).item()
    )
    mean_absolute_error = float(torch.mean(torch.abs(reference - output)).item())
    packed_ratio = packed_weight_bytes / original_weight_bytes
    output_elements_per_second = output.numel() * iterations / benchmark_seconds

    assertions.update(
        {
            "all_linear_layers_real_quantized": len(real_layers) == 2,
            "all_weights_nvfp4_packed": len(compressed_layers) == 2
            and all(name == "NVFP4QTensor" for name in packed_types),
            "finite_output": bool(torch.isfinite(output).all().item()),
            "modelopt_version_0_46_0": getattr(modelopt, "__version__", "unknown")
            == "0.46.0",
            "native_nvfp4_gemm_selected": native_backend_selected
            and len(kernel_implementations) == 2,
            "output_shape_matches": tuple(output.shape) == (batch_size, output_features),
            "packed_weight_ratio_at_most_0_30": packed_ratio <= 0.30,
            "positive_throughput": output_elements_per_second > 0.0,
            "reference_cosine_at_least_0_90": cosine_similarity >= 0.90,
            "tensorrt_llm_version_1_3_0rc24": backend_diagnostics.get(
                "tensorrt_llm_version"
            )
            == "1.3.0rc24",
        }
    )
    evidence.update(
        {
            "assertions": assertions,
            "diagnostics": {
                "compressed_layer_count": len(compressed_layers),
                "effective_bits_shim_count": effective_bits_shim_count,
                "kernel_implementations": kernel_implementations,
                "packed_types": packed_types,
                "backend": backend_diagnostics,
                "real_layer_count": len(real_layers),
                "real_quant_gemm_enabled": [
                    bool(getattr(module, "_use_real_quant_gemm", False))
                    for module in real_layers
                ],
            },
            "modelopt_version": getattr(modelopt, "__version__", "unknown"),
        }
    )
    failed_assertions = [name for name, passed in assertions.items() if not passed]
    if failed_assertions:
        raise RuntimeError("failed assertions: " + ", ".join(failed_assertions))
    if not math.isfinite(mean_absolute_error):
        raise RuntimeError("mean absolute error is not finite")

    evidence.update(
        {
            "assertions": assertions,
            "compatibility_adaptation": {
                "modelopt_0_46_effective_bits_metadata_shim": True,
                "quantizers_updated": effective_bits_shim_count,
                "value": 4.5,
            },
            "container_image": os.environ.get("GB10_CONTAINER_IMAGE", ""),
            "device": {
                "compute_capability": f"{capability[0]}.{capability[1]}",
                "index": device_index,
                "name": device_name,
                "total_memory_bytes": properties.total_memory,
            },
            "elapsed_seconds": round(time.perf_counter() - started, 4),
            "modelopt_version": getattr(modelopt, "__version__", "unknown"),
            "nvfp4": {
                "cosine_similarity_to_fp16": round(cosine_similarity, 8),
                "kernel_implementations": kernel_implementations,
                "mean_absolute_error": round(mean_absolute_error, 8),
                "original_weight_bytes": original_weight_bytes,
                "packed_weight_bytes": packed_weight_bytes,
                "packed_weight_ratio": round(packed_ratio, 8),
            },
            "status": "pass",
            "workload_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "torch": {
                "compiled_cuda": torch.version.cuda,
                "version": torch.__version__,
            },
            "workload": {
                "batch_size": batch_size,
                "dtype": "float16",
                "input_features": input_features,
                "iterations": iterations,
                "output_elements_per_second": round(output_elements_per_second, 2),
                "output_features": output_features,
                "seed": seed,
            },
        }
    )
    emit(evidence, 0)
except Exception as error:
    evidence.update(
        {
            "container_image": os.environ.get("GB10_CONTAINER_IMAGE", ""),
            "elapsed_seconds": round(time.perf_counter() - started, 4),
            "error": {"message": str(error), "type": type(error).__name__},
            "status": "fail",
        }
    )
    if os.environ.get("GB10_SMOKE_DEBUG") == "1":
        traceback.print_exc(file=sys.stderr)
    emit(evidence, 1)
