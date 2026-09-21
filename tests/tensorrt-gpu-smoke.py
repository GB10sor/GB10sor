#!/usr/bin/env python3
"""Build and execute a tiny TensorRT engine on one GB10 GPU."""

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import time
import traceback
from datetime import datetime, timezone


CUDA_MEMCPY_HOST_TO_DEVICE = 1
CUDA_MEMCPY_DEVICE_TO_HOST = 2
CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR = 75
CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR = 76


def emit(document: dict[str, object], exit_code: int) -> None:
    payload = json.dumps(document, separators=(",", ":"), sort_keys=True)
    print(f"GB10_EVIDENCE_JSON={payload}", flush=True)
    raise SystemExit(exit_code)


def has_default_route() -> bool:
    try:
        with open("/proc/net/route", encoding="ascii") as routes:
            next(routes, None)
            for line in routes:
                fields = line.split()
                if len(fields) >= 4 and fields[0] != "lo" and fields[1] == "00000000":
                    return True
    except FileNotFoundError:
        return True
    return False


class CudaRuntime:
    def __init__(self) -> None:
        self.library = ctypes.CDLL("libcudart.so")
        self.library.cudaGetErrorString.argtypes = [ctypes.c_int]
        self.library.cudaGetErrorString.restype = ctypes.c_char_p
        self.library.cudaGetDeviceCount.argtypes = [ctypes.POINTER(ctypes.c_int)]
        self.library.cudaSetDevice.argtypes = [ctypes.c_int]
        self.library.cudaRuntimeGetVersion.argtypes = [ctypes.POINTER(ctypes.c_int)]
        self.library.cudaMalloc.argtypes = [
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_size_t,
        ]
        self.library.cudaFree.argtypes = [ctypes.c_void_p]
        self.library.cudaMemcpy.argtypes = [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.c_int,
        ]
        self.library.cudaStreamCreate.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        self.library.cudaStreamSynchronize.argtypes = [ctypes.c_void_p]
        self.library.cudaStreamDestroy.argtypes = [ctypes.c_void_p]

    def check(self, status: int, operation: str) -> None:
        if status != 0:
            message = self.library.cudaGetErrorString(status)
            detail = message.decode("utf-8", errors="replace") if message else "unknown"
            raise RuntimeError(f"{operation} failed with CUDA error {status}: {detail}")

    def device_count(self) -> int:
        value = ctypes.c_int()
        self.check(self.library.cudaGetDeviceCount(ctypes.byref(value)), "cudaGetDeviceCount")
        return value.value

    def set_device(self, index: int) -> None:
        self.check(self.library.cudaSetDevice(index), "cudaSetDevice")

    def runtime_version(self) -> int:
        value = ctypes.c_int()
        self.check(
            self.library.cudaRuntimeGetVersion(ctypes.byref(value)),
            "cudaRuntimeGetVersion",
        )
        return value.value

    def malloc(self, size: int) -> ctypes.c_void_p:
        pointer = ctypes.c_void_p()
        self.check(self.library.cudaMalloc(ctypes.byref(pointer), size), "cudaMalloc")
        return pointer

    def free(self, pointer: ctypes.c_void_p) -> None:
        if pointer.value:
            self.check(self.library.cudaFree(pointer), "cudaFree")

    def memcpy(
        self,
        destination: ctypes.c_void_p,
        source: ctypes.c_void_p,
        size: int,
        kind: int,
    ) -> None:
        self.check(
            self.library.cudaMemcpy(destination, source, size, kind),
            "cudaMemcpy",
        )

    def create_stream(self) -> ctypes.c_void_p:
        stream = ctypes.c_void_p()
        self.check(
            self.library.cudaStreamCreate(ctypes.byref(stream)),
            "cudaStreamCreate",
        )
        return stream

    def synchronize(self, stream: ctypes.c_void_p) -> None:
        self.check(self.library.cudaStreamSynchronize(stream), "cudaStreamSynchronize")

    def destroy_stream(self, stream: ctypes.c_void_p) -> None:
        if stream.value:
            self.check(self.library.cudaStreamDestroy(stream), "cudaStreamDestroy")


class CudaDriver:
    def __init__(self) -> None:
        self.library = ctypes.CDLL("libcuda.so.1")
        self.library.cuInit.argtypes = [ctypes.c_uint]
        self.library.cuDeviceGet.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_int]
        self.library.cuDeviceGetName.argtypes = [
            ctypes.POINTER(ctypes.c_char),
            ctypes.c_int,
            ctypes.c_int,
        ]
        self.library.cuDeviceGetAttribute.argtypes = [
            ctypes.POINTER(ctypes.c_int),
            ctypes.c_int,
            ctypes.c_int,
        ]
        try:
            self.device_total_mem = self.library.cuDeviceTotalMem_v2
        except AttributeError:
            self.device_total_mem = self.library.cuDeviceTotalMem
        self.device_total_mem.argtypes = [
            ctypes.POINTER(ctypes.c_size_t),
            ctypes.c_int,
        ]
        self.check(self.library.cuInit(0), "cuInit")

    @staticmethod
    def check(status: int, operation: str) -> None:
        if status != 0:
            raise RuntimeError(f"{operation} failed with CUDA driver error {status}")

    def device(self, index: int) -> int:
        value = ctypes.c_int()
        self.check(self.library.cuDeviceGet(ctypes.byref(value), index), "cuDeviceGet")
        return value.value

    def device_name(self, device: int) -> str:
        value = ctypes.create_string_buffer(256)
        self.check(
            self.library.cuDeviceGetName(value, len(value), device),
            "cuDeviceGetName",
        )
        return value.value.decode("utf-8", errors="replace")

    def attribute(self, device: int, attribute: int) -> int:
        value = ctypes.c_int()
        self.check(
            self.library.cuDeviceGetAttribute(
                ctypes.byref(value), attribute, device
            ),
            "cuDeviceGetAttribute",
        )
        return value.value

    def total_memory(self, device: int) -> int:
        value = ctypes.c_size_t()
        self.check(
            self.device_total_mem(ctypes.byref(value), device),
            "cuDeviceTotalMem",
        )
        return value.value


started = time.perf_counter()
evidence: dict[str, object] = {
    "schema_version": 1,
    "test": "tensorrt-tiny-engine",
    "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "image_reference": os.environ.get("GB10_TENSORRT_IMAGE_REFERENCE", ""),
}

source_device = ctypes.c_void_p()
destination_device = ctypes.c_void_p()
stream = ctypes.c_void_p()
cuda: CudaRuntime | None = None
try:
    import tensorrt as trt

    expected_version = os.environ["GB10_TENSORRT_EXPECTED_VERSION"]
    expected_cuda_prefix = os.environ["GB10_TENSORRT_EXPECTED_CUDA_PREFIX"]
    expected_cuda_environment = os.environ["GB10_TENSORRT_EXPECTED_CUDA_ENV"]
    actual_version = str(trt.__version__)
    if actual_version != expected_version:
        raise RuntimeError(
            f"expected TensorRT {expected_version}, found {actual_version}"
        )

    cuda = CudaRuntime()
    driver = CudaDriver()
    if cuda.device_count() < 1:
        raise RuntimeError("no CUDA device is available")
    device_index = int(os.environ.get("GB10_CUDA_DEVICE", "0"))
    if device_index < 0 or device_index >= cuda.device_count():
        raise RuntimeError("GB10_CUDA_DEVICE is outside the enumerated range")
    cuda.set_device(device_index)
    driver_device = driver.device(device_index)
    device_name = driver.device_name(driver_device)
    capability = (
        driver.attribute(driver_device, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR),
        driver.attribute(driver_device, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR),
    )
    total_memory = driver.total_memory(driver_device)
    cuda_runtime_integer = cuda.runtime_version()
    cuda_runtime = (
        f"{cuda_runtime_integer // 1000}."
        f"{(cuda_runtime_integer % 1000) // 10}"
    )

    assertions = {
        "compute_capability_12_1": capability == (12, 1),
        "credentials_absent": not any(
            os.environ.get(name)
            for name in (
                "AWS_ACCESS_KEY_ID",
                "AWS_SECRET_ACCESS_KEY",
                "HF_TOKEN",
                "HUGGING_FACE_HUB_TOKEN",
                "NGC_API_KEY",
                "NVIDIA_API_KEY",
            )
        ),
        "cuda_available": True,
        "cuda_environment_exact": os.environ.get("CUDA_VERSION")
        == expected_cuda_environment,
        "cuda_runtime_expected": cuda_runtime.startswith(expected_cuda_prefix),
        "device_name_contains_gb10": "GB10" in device_name.upper(),
        "expected_tensorrt_version": actual_version == expected_version,
        "network_disabled": not has_default_route(),
        "proxy_environment_absent": not any(
            os.environ.get(name)
            for name in (
                "ALL_PROXY",
                "HTTP_PROXY",
                "HTTPS_PROXY",
                "all_proxy",
                "http_proxy",
                "https_proxy",
            )
        ),
    }
    failed = [name for name, passed in assertions.items() if not passed]
    if failed:
        raise RuntimeError("failed preconditions: " + ", ".join(failed))

    logger = trt.Logger(trt.Logger.ERROR)
    builder = trt.Builder(logger)
    explicit_batch_flag = getattr(
        trt.NetworkDefinitionCreationFlag, "EXPLICIT_BATCH", None
    )
    network_flags = (
        0 if explicit_batch_flag is None else 1 << int(explicit_batch_flag)
    )
    network = builder.create_network(network_flags)
    input_tensor = network.add_input("input", trt.float32, (1, 16))
    if input_tensor is None:
        raise RuntimeError("TensorRT failed to create the input tensor")
    identity = network.add_identity(input_tensor)
    if identity is None:
        raise RuntimeError("TensorRT failed to create the identity layer")
    output_tensor = identity.get_output(0)
    output_tensor.name = "output"
    network.mark_output(output_tensor)

    config = builder.create_builder_config()
    config.set_memory_pool_limit(trt.MemoryPoolType.WORKSPACE, 256 << 20)
    build_started = time.perf_counter()
    serialized = builder.build_serialized_network(network, config)
    build_seconds = time.perf_counter() - build_started
    if serialized is None:
        raise RuntimeError("TensorRT failed to build the serialized engine")

    engine_bytes = bytes(serialized)
    runtime = trt.Runtime(logger)
    engine = runtime.deserialize_cuda_engine(serialized)
    if engine is None:
        raise RuntimeError("TensorRT failed to deserialize the engine")
    context = engine.create_execution_context()
    if context is None:
        raise RuntimeError("TensorRT failed to create an execution context")

    element_count = 16
    byte_count = element_count * ctypes.sizeof(ctypes.c_float)
    source_host = (ctypes.c_float * element_count)(
        *(float(value) for value in range(element_count))
    )
    destination_host = (ctypes.c_float * element_count)()
    source_device = cuda.malloc(byte_count)
    destination_device = cuda.malloc(byte_count)
    cuda.memcpy(
        source_device,
        ctypes.cast(source_host, ctypes.c_void_p),
        byte_count,
        CUDA_MEMCPY_HOST_TO_DEVICE,
    )
    stream = cuda.create_stream()
    if not context.set_tensor_address("input", int(source_device.value)):
        raise RuntimeError("TensorRT rejected the input address")
    if not context.set_tensor_address("output", int(destination_device.value)):
        raise RuntimeError("TensorRT rejected the output address")
    execute_started = time.perf_counter()
    executed = context.execute_async_v3(int(stream.value))
    cuda.synchronize(stream)
    execute_seconds = time.perf_counter() - execute_started
    if not executed:
        raise RuntimeError("TensorRT execute_async_v3 returned false")
    cuda.memcpy(
        ctypes.cast(destination_host, ctypes.c_void_p),
        destination_device,
        byte_count,
        CUDA_MEMCPY_DEVICE_TO_HOST,
    )

    observed = [float(value) for value in destination_host]
    expected = [float(value) for value in range(element_count)]
    max_abs_error = max(abs(left - right) for left, right in zip(observed, expected))
    output_sum = sum(observed)
    assertions.update(
        {
            "engine_built": len(engine_bytes) > 0,
            "engine_executed": executed,
            "numeric_result_exact": max_abs_error == 0.0 and output_sum == 120.0,
            "raw_cuda_buffers_used": True,
        }
    )
    failed = [name for name, passed in assertions.items() if not passed]
    if failed:
        raise RuntimeError("failed assertions: " + ", ".join(failed))

    evidence.update(
        {
            "assertions": assertions,
            "device": {
                "compute_capability": f"{capability[0]}.{capability[1]}",
                "index": device_index,
                "name": device_name,
                "total_memory_bytes": total_memory,
            },
            "elapsed_seconds": round(time.perf_counter() - started, 4),
            "software": {
                "cuda_runtime": cuda_runtime,
                "explicit_batch_flag_available": explicit_batch_flag is not None,
                "tensorrt": actual_version,
            },
            "status": "pass",
            "workload": {
                "build_seconds": round(build_seconds, 4),
                "engine_bytes": len(engine_bytes),
                "engine_sha256": hashlib.sha256(engine_bytes).hexdigest(),
                "execute_seconds": round(execute_seconds, 6),
                "input_shape": [1, 16],
                "max_abs_error": max_abs_error,
                "operation": "output = identity(input)",
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
finally:
    if cuda is not None:
        try:
            cuda.destroy_stream(stream)
            cuda.free(destination_device)
            cuda.free(source_device)
        except Exception:
            if os.environ.get("GB10_SMOKE_DEBUG") == "1":
                traceback.print_exc()
