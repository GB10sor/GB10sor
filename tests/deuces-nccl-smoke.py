#!/usr/bin/env python3
"""Fail-closed two-rank NCCL functional smoke test for one GPU per node."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import platform
import resource
import time
from pathlib import Path

import torch
import torch.distributed as dist


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rank", required=True, type=int, choices=(0, 1))
    parser.add_argument("--world-size", default=2, type=int)
    parser.add_argument("--master-address", required=True)
    parser.add_argument("--master-port", required=True, type=int)
    parser.add_argument("--elements", default=16 * 1024 * 1024, type=int)
    parser.add_argument("--iterations", default=8, type=int)
    parser.add_argument("--collective-timeout", default=180, type=int)
    parser.add_argument("--exit-after-initial-barrier", action="store_true")
    parser.add_argument("--exercise-sglang-groups", action="store_true")
    parser.add_argument("--result-file", required=True)
    return parser.parse_args()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> None:
    args = parse_args()
    require(args.world_size == 2, "this bounded harness requires exactly two ranks")
    require(args.elements > 0 and args.iterations >= 3, "invalid workload bounds")
    require(platform.machine() == "aarch64", "expected aarch64")
    require(torch.cuda.is_available(), "torch.cuda.is_available() is false")
    require(torch.cuda.device_count() == 1, "expected exactly one visible GPU per rank")
    memlock = resource.getrlimit(resource.RLIMIT_MEMLOCK)
    require(
        memlock == (resource.RLIM_INFINITY, resource.RLIM_INFINITY),
        f"expected unlimited memlock, got {memlock}",
    )

    torch.cuda.set_device(0)
    capability = tuple(torch.cuda.get_device_capability(0))
    require(capability == (12, 1), f"expected compute capability 12.1, got {capability}")

    init_method = f"tcp://{args.master_address}:{args.master_port}"
    dist.init_process_group(
        backend="nccl",
        init_method=init_method,
        rank=args.rank,
        world_size=args.world_size,
        timeout=dt.timedelta(seconds=args.collective_timeout),
    )

    gloo_group = None
    sglang_groups_initialized = False
    destroy_model_parallel = None
    destroy_distributed_environment = None
    try:
        if args.exercise_sglang_groups:
            from sglang.srt.distributed import (
                destroy_distributed_environment,
                destroy_model_parallel,
                get_tp_group,
                init_distributed_environment,
                initialize_model_parallel,
                set_custom_all_reduce,
            )

            os.environ["LOCAL_SIZE"] = str(args.world_size)
            set_custom_all_reduce(False)
            init_distributed_environment(
                backend="nccl",
                world_size=args.world_size,
                rank=args.rank,
                local_rank=0,
                distributed_init_method=init_method,
                timeout=args.collective_timeout,
            )
            initialize_model_parallel(tensor_model_parallel_size=args.world_size)
            tp_group = get_tp_group()
            gloo_group = tp_group.cpu_group
            sglang_device_group = tp_group.device_group
            sglang_groups_initialized = True
        else:
            gloo_group = dist.new_group(
                ranks=list(range(args.world_size)),
                backend="gloo",
                timeout=dt.timedelta(seconds=args.collective_timeout),
            )
        cpu_scalar = torch.tensor([float(args.rank + 1)], device="cpu")
        dist.all_reduce(cpu_scalar, op=dist.ReduceOp.SUM, group=gloo_group)
        require(
            cpu_scalar.item() == 3.0,
            f"gloo all_reduce scalar mismatch: {cpu_scalar.item()}",
        )
        sglang_group_scalar = None
        if args.exercise_sglang_groups:
            sglang_group_tensor = torch.tensor(
                [float(args.rank + 1)], device="cuda"
            )
            dist.all_reduce(sglang_group_tensor, group=sglang_device_group)
            torch.cuda.synchronize()
            sglang_group_scalar = sglang_group_tensor.item()
            require(
                sglang_group_scalar == 3.0,
                f"SGLang TP-group all_reduce mismatch: {sglang_group_scalar}",
            )

        dist.barrier()

        if args.exit_after_initial_barrier:
            print("GB10_INJECTED_WORKER_FAILURE=rank1", flush=True)
            os._exit(86)

        scalar = torch.tensor([float(args.rank + 1)], device="cuda")
        dist.all_reduce(scalar, op=dist.ReduceOp.SUM)
        torch.cuda.synchronize()
        require(scalar.item() == 3.0, f"all_reduce scalar mismatch: {scalar.item()}")

        broadcast = torch.tensor(
            [42.25 if args.rank == 0 else -1.0], dtype=torch.float32, device="cuda"
        )
        dist.broadcast(broadcast, src=0)
        torch.cuda.synchronize()
        require(broadcast.item() == 42.25, f"broadcast mismatch: {broadcast.item()}")

        gathered = [torch.zeros(1, device="cuda") for _ in range(args.world_size)]
        own = torch.tensor([float(args.rank + 1)], device="cuda")
        dist.all_gather(gathered, own)
        torch.cuda.synchronize()
        gathered_values = [item.item() for item in gathered]
        require(gathered_values == [1.0, 2.0], f"all_gather mismatch: {gathered_values}")

        payload = torch.empty(args.elements, dtype=torch.float32, device="cuda")
        dist.barrier()
        torch.cuda.synchronize()
        started = time.monotonic()
        for _ in range(args.iterations):
            payload.fill_(float(args.rank + 1))
            dist.all_reduce(payload, op=dist.ReduceOp.SUM)
        torch.cuda.synchronize()
        duration = time.monotonic() - started

        first = payload[0].item()
        last = payload[-1].item()
        checksum = payload.sum(dtype=torch.float64).item()
        expected_checksum = 3.0 * args.elements
        require(first == 3.0 and last == 3.0, "large all_reduce boundary mismatch")
        require(
            math.isclose(checksum, expected_checksum, rel_tol=0.0, abs_tol=0.0),
            f"large all_reduce checksum mismatch: {checksum} != {expected_checksum}",
        )

        bytes_per_iteration = payload.numel() * payload.element_size()
        algorithm_gbps = bytes_per_iteration * args.iterations * 8 / duration / 1e9
        result = {
            "result": "pass",
            "rank": args.rank,
            "world_size": args.world_size,
            "backend": dist.get_backend(),
            "sglang_groups_initialized": sglang_groups_initialized,
            "operations": {
                "gloo_all_reduce_scalar": cpu_scalar.item(),
                "sglang_group_all_reduce_scalar": sglang_group_scalar,
                "all_reduce_scalar": scalar.item(),
                "broadcast": broadcast.item(),
                "all_gather": gathered_values,
                "large_all_reduce_checksum": checksum,
                "large_all_reduce_expected_checksum": expected_checksum,
            },
            "workload": {
                "elements": args.elements,
                "iterations": args.iterations,
                "bytes_per_iteration": bytes_per_iteration,
                "duration_seconds": duration,
                "algorithm_gbps": algorithm_gbps,
            },
            "software": {
                "torch": torch.__version__,
                "torch_cuda": torch.version.cuda,
                "nccl": list(torch.cuda.nccl.version()),
            },
            "hardware": {
                "architecture": platform.machine(),
                "device": torch.cuda.get_device_name(0),
                "capability": list(capability),
                "memlock": [memlock[0], memlock[1]],
            },
            "network_policy": {
                "nccl_ib_disable": os.environ.get("NCCL_IB_DISABLE"),
                "nccl_ib_hca": os.environ.get("NCCL_IB_HCA"),
                "nccl_ib_gid_index": os.environ.get("NCCL_IB_GID_INDEX"),
                "nccl_socket_ifname": os.environ.get("NCCL_SOCKET_IFNAME"),
                "gloo_socket_ifname": os.environ.get("GLOO_SOCKET_IFNAME"),
                "nccl_cumem_enable": os.environ.get("NCCL_CUMEM_ENABLE"),
                "nccl_mnnvl_enable": os.environ.get("NCCL_MNNVL_ENABLE"),
                "sglang_use_message_queue_broadcaster": os.environ.get(
                    "SGLANG_USE_MESSAGE_QUEUE_BROADCASTER"
                ),
            },
        }
        serialized = json.dumps(result, sort_keys=True)
        Path(args.result_file).write_text(serialized + "\n", encoding="utf-8")
        print("GB10_NCCL_RESULT=" + serialized, flush=True)
    finally:
        if args.exercise_sglang_groups:
            if destroy_model_parallel is not None:
                destroy_model_parallel()
            if destroy_distributed_environment is not None:
                destroy_distributed_environment()
        else:
            if gloo_group is not None:
                dist.destroy_process_group(gloo_group)
            dist.destroy_process_group()


if __name__ == "__main__":
    main()
