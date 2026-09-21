#!/usr/bin/env python3
"""Build and execute a tiny TensorRT engine inside the pinned TRT-LLM image."""

from __future__ import annotations

import hashlib
import json
import os
import time
import traceback
from datetime import datetime, timezone


def emit(document: dict[str, object], exit_code: int) -> None:
    payload = json.dumps(document, separators=(",", ":"), sort_keys=True)
    print(f"GB10_EVIDENCE_JSON={payload}", flush=True)
    raise SystemExit(exit_code)


started = time.perf_counter()
evidence: dict[str, object] = {
    "schema_version": 1,
    "test": "trt-llm-tiny-tensorrt-engine",
    "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "image_reference": os.environ.get("GB10_TRT_LLM_IMAGE_REFERENCE", ""),
}

try:
    import numpy as np
    import tensorrt as trt
    import tensorrt_llm
    import torch

    expected_trt_llm_version = os.environ.get(
        "GB10_TRT_LLM_EXPECTED_VERSION", "1.2.0rc6"
    )
    trt_llm_version = str(tensorrt_llm.__version__)
    if trt_llm_version != expected_trt_llm_version:
        raise RuntimeError(
            "expected TensorRT-LLM "
            f"{expected_trt_llm_version}, found {trt_llm_version}"
        )

    if not torch.cuda.is_available():
        raise RuntimeError("torch.cuda.is_available() is false")
    if torch.cuda.device_count() < 1:
        raise RuntimeError("no CUDA devices were enumerated")

    device_index = int(os.environ.get("GB10_CUDA_DEVICE", "0"))
    if device_index < 0 or device_index >= torch.cuda.device_count():
        raise RuntimeError(
            f"CUDA device index {device_index} is outside "
            f"0..{torch.cuda.device_count() - 1}"
        )

    torch.cuda.set_device(device_index)
    device = torch.device("cuda", device_index)
    properties = torch.cuda.get_device_properties(device_index)
    capability = tuple(torch.cuda.get_device_capability(device_index))
    device_name = properties.name

    assertions = {
        "compute_capability_12_1": capability == (12, 1),
        "credentials_absent": not any(
            os.environ.get(name)
            for name in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "NGC_API_KEY")
        ),
        "cuda_available": True,
        "device_name_contains_gb10": "GB10" in device_name.upper(),
        "expected_trt_llm_version": trt_llm_version == expected_trt_llm_version,
        "network_disabled": os.environ.get("HF_HUB_OFFLINE") == "1",
    }
    failed_preconditions = [
        name for name, passed in assertions.items() if not passed
    ]
    if failed_preconditions:
        raise RuntimeError(
            "failed preconditions: " + ", ".join(failed_preconditions)
        )

    logger = trt.Logger(trt.Logger.ERROR)
    builder = trt.Builder(logger)
    explicit_batch = 1 << int(trt.NetworkDefinitionCreationFlag.EXPLICIT_BATCH)
    network = builder.create_network(explicit_batch)
    input_tensor = network.add_input(
        name="input", dtype=trt.float32, shape=(1, 16)
    )
    if input_tensor is None:
        raise RuntimeError("TensorRT failed to create the input tensor")

    addend = np.full((1, 16), 2.0, dtype=np.float32)
    constant_layer = network.add_constant(addend.shape, addend)
    add_layer = network.add_elementwise(
        input_tensor,
        constant_layer.get_output(0),
        trt.ElementWiseOperation.SUM,
    )
    output_tensor = add_layer.get_output(0)
    output_tensor.name = "output"
    network.mark_output(output_tensor)

    config = builder.create_builder_config()
    config.set_memory_pool_limit(trt.MemoryPoolType.WORKSPACE, 256 << 20)
    build_started = time.perf_counter()
    serialized_engine = builder.build_serialized_network(network, config)
    build_seconds = time.perf_counter() - build_started
    if serialized_engine is None:
        raise RuntimeError("TensorRT failed to build the serialized engine")

    engine_bytes = bytes(serialized_engine)
    runtime = trt.Runtime(logger)
    engine = runtime.deserialize_cuda_engine(serialized_engine)
    if engine is None:
        raise RuntimeError("TensorRT failed to deserialize the engine")
    context = engine.create_execution_context()
    if context is None:
        raise RuntimeError("TensorRT failed to create an execution context")

    source = torch.arange(16, dtype=torch.float32, device=device).reshape(1, 16)
    destination = torch.empty_like(source)
    stream = torch.cuda.Stream(device=device)
    torch.cuda.synchronize(device)

    if not context.set_tensor_address("input", int(source.data_ptr())):
        raise RuntimeError("TensorRT rejected the input tensor address")
    if not context.set_tensor_address("output", int(destination.data_ptr())):
        raise RuntimeError("TensorRT rejected the output tensor address")

    execute_started = time.perf_counter()
    executed = context.execute_async_v3(int(stream.cuda_stream))
    stream.synchronize()
    execute_seconds = time.perf_counter() - execute_started
    if not executed:
        raise RuntimeError("TensorRT execute_async_v3 returned false")

    expected = source + 2.0
    max_abs_error = float(torch.max(torch.abs(destination - expected)).item())
    output_sum = float(destination.sum().item())
    assertions.update(
        {
            "engine_built": len(engine_bytes) > 0,
            "engine_executed": executed,
            "numeric_result_exact": max_abs_error == 0.0 and output_sum == 152.0,
            "output_on_cuda": destination.is_cuda,
        }
    )
    failed_assertions = [name for name, passed in assertions.items() if not passed]
    if failed_assertions:
        raise RuntimeError("failed assertions: " + ", ".join(failed_assertions))

    evidence.update(
        {
            "assertions": assertions,
            "device": {
                "compute_capability": f"{capability[0]}.{capability[1]}",
                "index": device_index,
                "name": device_name,
                "total_memory_bytes": properties.total_memory,
            },
            "elapsed_seconds": round(time.perf_counter() - started, 4),
            "status": "pass",
            "software": {
                "compiled_cuda": torch.version.cuda,
                "tensorrt": trt.__version__,
                "tensorrt_llm": trt_llm_version,
                "torch": torch.__version__,
            },
            "workload": {
                "build_seconds": round(build_seconds, 4),
                "engine_bytes": len(engine_bytes),
                "engine_sha256": hashlib.sha256(engine_bytes).hexdigest(),
                "execute_seconds": round(execute_seconds, 6),
                "input_shape": [1, 16],
                "max_abs_error": max_abs_error,
                "operation": "output = input + 2.0",
                "output_sum": output_sum,
            },
        }
    )
    emit(evidence, 0)
except Exception as error:
    evidence.update(
        {
            "elapsed_seconds": round(time.perf_counter() - started, 4),
            "error": {"message": str(error), "type": type(error).__name__},
            "status": "fail",
        }
    )
    if os.environ.get("GB10_SMOKE_DEBUG") == "1":
        traceback.print_exc()
    emit(evidence, 1)
