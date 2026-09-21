#!/usr/bin/env bash
set -Eeuo pipefail

# One-command coordinator for the evidence-backed Spark05/Spark06 switched
# Deuces boundary. It never changes NixOS, downloads a checkpoint, or exposes
# an endpoint beyond rank 0's loopback interface. The acceptance harness is
# fail-closed and removes its temporary containers, firewall rules, and test
# files before returning. qualify-and-serve keeps the already-qualified
# loopback endpoint alive in the foreground and performs the same cleanup when
# it stops.

die() {
  printf 'Deuces-switch launcher failed: %s\n' "$*" >&2
  exit 1
}

mode="${1:-acceptance}"
profile="${GB10_MODEL_PROFILE:-}"
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
evidence_root="${GB10_PRIVATE_EVIDENCE_ROOT:-$HOME/.local/state/gb10sor/private-evidence}"
config_file="${GB10_DEUCES_SWITCH_CONFIG:-$HOME/.config/gb10sor/deuces-switch.env}"

[[ -r "$config_file" ]] || die "private switched-pair config is unreadable: $config_file"
# shellcheck disable=SC1090
source "$config_file"

# Keep the private coordinator configuration self-contained. These values are
# optional because the reviewed switched-fabric defaults are safe, but when a
# user supplies one it must reach the engine-specific acceptance process.
for name in \
  DEUCES_SSH_IDENTITY_FILE DEUCES_SSH_KNOWN_HOSTS_FILE \
  DEUCES_RAIL_A_INTERFACE DEUCES_RAIL_B_INTERFACE \
  DEUCES_NCCL_IB_HCA DEUCES_NCCL_IB_GID_INDEX \
  DEUCES_NCCL_SOCKET_IFNAME DEUCES_MTU DEUCES_DIRECT_INTERFACE_COUNT \
  DEUCES_SGLANG_IMAGE DEUCES_SGLANG_EXPECTED_IMAGE_ID \
  DEUCES_SGLANG_EXPECTED_LAYERS_SHA256 \
  DEUCES_VLLM_ENFORCE_EAGER
do
  [[ -z "${!name:-}" ]] || export "$name"
done

case "$mode" in
  acceptance)
    export DEUCES_QUALIFY_AND_SERVE=0
    ;;
  qualify-and-serve)
    export DEUCES_QUALIFY_AND_SERVE=1
    ;;
  *)
    die 'mode must be acceptance or qualify-and-serve'
    ;;
esac
[[ -n "$profile" ]] || die 'GB10_MODEL_PROFILE is not set; use a deuces-switch-* Nix shell'
[[ "$evidence_root" == /* && "$evidence_root" != / ]] || die 'private evidence root must be a safe absolute path'

for name in DEUCES_LEFT_HOST DEUCES_RIGHT_HOST DEUCES_LEFT_NODE DEUCES_RIGHT_NODE \
  DEUCES_LEFT_RAIL_A DEUCES_RIGHT_RAIL_A \
  DEUCES_CLUSTER_PROFILE_PATH \
  DEUCES_LEFT_MODEL_ROOT DEUCES_RIGHT_MODEL_ROOT
do
  [[ -n "${!name:-}" ]] || die "private config is missing: $name"
done
interface_count="${DEUCES_DIRECT_INTERFACE_COUNT:-2}"
[[ "$interface_count" == 1 || "$interface_count" == 2 ]] || \
  die 'DEUCES_DIRECT_INTERFACE_COUNT must be 1 or 2'
if [[ "$interface_count" == 2 ]]; then
  for name in DEUCES_LEFT_RAIL_B DEUCES_RIGHT_RAIL_B; do
    [[ -n "${!name:-}" ]] || die "private config is missing: $name"
  done
fi
export DEUCES_LEFT_HOST DEUCES_RIGHT_HOST DEUCES_LEFT_NODE DEUCES_RIGHT_NODE
export DEUCES_LEFT_RAIL_A DEUCES_RIGHT_RAIL_A DEUCES_DIRECT_INTERFACE_COUNT
if [[ "$interface_count" == 2 ]]; then
  export DEUCES_LEFT_RAIL_B DEUCES_RIGHT_RAIL_B
fi
export DEUCES_CLUSTER_PROFILE_PATH
export DEUCES_MODEL_PROFILE="$profile"
export DEUCES_MODEL_PROFILE_REGISTRY="${DEUCES_MODEL_PROFILE_REGISTRY:-${GB10_MODEL_PROFILE_REGISTRY:-$repo_root/model-profiles.json}}"

engine=''
case "$profile" in
  qwen38-flash-next|qwen38-flash-next-direct-bounded)
    engine=sglang
    model_suffix=RadixArk/Qwen3.8-Flash-Next-NVFP4
    ;;
  qwen38-flash-next-nvidia-vllm)
    engine=vllm
    model_suffix=nvidia/Qwen3.8-Flash-Next-NVFP4
    ;;
  laguna-s21-nvfp4)
    engine=vllm
    model_suffix=poolside/Laguna-S-2.1-NVFP4
    auxiliary_suffix=poolside/Laguna-S-2.1-DFlash-NVFP4
    ;;
  deepseek-v4-sglang-target-only)
    engine=sglang
    model_suffix=nvidia/DeepSeek-V4-Flash-nvfp4-DSpark
    ;;
  deepseek-v4-target-v028-fi0617-sm121-o-proj)
    engine=vllm
    model_suffix=nvidia/DeepSeek-V4-Flash-nvfp4-DSpark
    ;;
  deepseek-v4-nvidia-anemll-vllm)
    engine=vllm
    model_suffix=nvidia/DeepSeek-V4-Flash-nvfp4-DSpark
    ;;
  deepseek-v4-flash-0731-nvidia-vllm|deepseek-v4-flash-0731-nvidia-v028)
    engine=vllm
    model_suffix=nvidia/DeepSeek-V4-Flash-0731-NVFP4
    ;;
  deepseek-v41-flash-exl3-29bpw)
    engine=vllm
    [[ "${DEUCES_TOPOLOGY:-switch}" == direct && "$interface_count" == 1 ]] || \
      die 'DeepSeek V4.1 Flash EXL3 requires single-primary Deuces-direct'
    model_suffix=Mia-AiLab/DeepSeek-V4.1-Flash-EXL3-2.9bpw
    export DEUCES_LEFT_AUXILIARY_MODEL_DIR="${DEUCES_LEFT_AUXILIARY_MODEL_DIR:-${HOME:?}/.local/share/gb10sor-engram/deepseek-v41/rank0}"
    export DEUCES_RIGHT_AUXILIARY_MODEL_DIR="${DEUCES_RIGHT_AUXILIARY_MODEL_DIR:-${HOME:?}/.local/share/gb10sor-engram/deepseek-v41/rank1}"
    export DEUCES_VLLM_STARTUP_TIMEOUT_SECONDS="${DEUCES_VLLM_STARTUP_TIMEOUT_SECONDS:-2400}"
    ;;
  inkling-small-nvfp4-sglang-dspark)
    engine=sglang
    model_suffix=thinkingmachines/Inkling-Small-NVFP4
    draft_suffix=RadixArk/Inkling-Small-DSpark-Preview
    ;;
  glm53-flash-nvfp4-sglang-dflash2|glm53-flash-nvfp4-sglang-target-only)
    engine=sglang
    glm_target_revision=$(jq -er --arg profile "$profile" \
      '.profiles[$profile].modelRevision | select(test("^[a-f0-9]{40}$"))' \
      "$DEUCES_MODEL_PROFILE_REGISTRY") || \
      die 'GLM target revision is missing or invalid in the selected model registry'
    model_suffix="LibertAIDAI/GLM-5.3-Flash-NVFP4.rev-$glm_target_revision"
    if [[ "$profile" == glm53-flash-nvfp4-sglang-target-only ]]; then
      [[ "${DEUCES_TOPOLOGY:-switch}" == direct && "$interface_count" == 1 ]] || \
        die 'GLM target-only candidate requires single-primary Deuces-direct'
      unset DEUCES_LEFT_DRAFT_MODEL_DIR DEUCES_RIGHT_DRAFT_MODEL_DIR
    else
      glm_draft_revision=$(jq -er --arg profile "$profile" \
        '.profiles[$profile].speculative.modelRevision | select(test("^[a-f0-9]{40}$"))' \
        "$DEUCES_MODEL_PROFILE_REGISTRY") || \
        die 'GLM draft revision is missing or invalid in the selected model registry'
      draft_suffix="incoai/GLM-5.3-Flash-DFlash2.rev-$glm_draft_revision"
    fi
    export DEUCES_SGLANG_IPC_MODE=host
    export DEUCES_SGLANG_START_ORDER=worker-first
    export DEUCES_SGLANG_NCCL_CUMEM_ENABLE=0
    export DEUCES_SGLANG_NCCL_NVLS_ENABLE=0
    export DEUCES_TP_SOCKET_IFNAME="${DEUCES_TP_SOCKET_IFNAME:-enp1s0f1np1}"
    ;;
  *)
    die "profile is not enabled for the qualified Deuces-switch boundary: $profile"
    ;;
esac

export DEUCES_LEFT_MODEL_DIR="${DEUCES_LEFT_MODEL_DIR:-$DEUCES_LEFT_MODEL_ROOT/$model_suffix}"
export DEUCES_RIGHT_MODEL_DIR="${DEUCES_RIGHT_MODEL_DIR:-$DEUCES_RIGHT_MODEL_ROOT/$model_suffix}"
if [[ -n "${auxiliary_suffix:-}" ]]; then
  export DEUCES_LEFT_AUXILIARY_MODEL_DIR="${DEUCES_LEFT_AUXILIARY_MODEL_DIR:-$DEUCES_LEFT_MODEL_ROOT/$auxiliary_suffix}"
  export DEUCES_RIGHT_AUXILIARY_MODEL_DIR="${DEUCES_RIGHT_AUXILIARY_MODEL_DIR:-$DEUCES_RIGHT_MODEL_ROOT/$auxiliary_suffix}"
fi
if [[ -n "${draft_suffix:-}" ]]; then
  export DEUCES_LEFT_DRAFT_MODEL_DIR="${DEUCES_LEFT_DRAFT_MODEL_DIR:-$DEUCES_LEFT_MODEL_ROOT/$draft_suffix}"
  export DEUCES_RIGHT_DRAFT_MODEL_DIR="${DEUCES_RIGHT_DRAFT_MODEL_DIR:-$DEUCES_RIGHT_MODEL_ROOT/$draft_suffix}"
fi

run_id=$(date -u +%Y%m%dT%H%M%SZ)
export DEUCES_PAYLOAD_EVIDENCE_DIR="${DEUCES_PAYLOAD_EVIDENCE_DIR:-$evidence_root/deuces-switch-$profile-$run_id}"

[[ "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 0 || "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 1 ]] ||
  die 'owned lifecycle mode must be0 or1'
if [[ "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 1 ]]; then
  # Explicit finite candidate only. Parent records the pre-write declaration;
  # this local supervisor is not a replacement for durable network rollback.
  [[ "${GB10_DEUCES_PARENT_RUNTIME_SECONDS:-}" =~ ^[1-9][0-9]*$ ]] || \
    die 'owned mode requires explicit finite GB10_DEUCES_PARENT_RUNTIME_SECONDS'
  exec "${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I "$repo_root/scripts/deuces-resource-parent.py" "$engine"
fi

case "$engine" in
  vllm) exec "$repo_root/scripts/deuces-vllm-acceptance.sh" ;;
  sglang) exec "$repo_root/scripts/deuces-sglang-acceptance.sh" ;;
  *) die "unsupported engine: $engine" ;;
esac
