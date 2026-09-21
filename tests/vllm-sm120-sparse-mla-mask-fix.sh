#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
patcher="$repo_root/containers/vllm-0.28-sm120-sparse-mla-mask-fix/apply-sm120-sparse-mla-fix.py"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fixture="$work/flashinfer_mla_sparse_sm120.py"

printf '%s\n' \
  'class FlashInferMLASparseSM120Impl:' \
  '    is_sparse = True' \
  >"$fixture"
GB10_VLLM_SM120_SOURCE_PATH="$fixture" python3 "$patcher"
grep -Fxc '    masked_mha_available = False' "$fixture" >/dev/null

if GB10_VLLM_SM120_SOURCE_PATH="$fixture" python3 "$patcher" >/dev/null 2>&1; then
  printf 'FAIL: patcher accepted an already patched source\n' >&2
  exit 1
fi

printf '%s\n' 'class FlashInferMLASparseSM120Impl: pass' >"$fixture"
if GB10_VLLM_SM120_SOURCE_PATH="$fixture" python3 "$patcher" >/dev/null 2>&1; then
  printf 'FAIL: patcher accepted an unexpected source\n' >&2
  exit 1
fi

printf 'PASS: SM120 sparse-MLA patch is exact and fail-closed\n'
