#!/usr/bin/env bash

# Shared, side-effect-free container-engine selection for the bounded Solo
# acceptance test. Podman is preferred only when it is rootless and a valid
# NVIDIA CDI device is present. Docker is accepted only when the current user
# can already reach the daemon; this script never changes group membership,
# socket permissions, daemon configuration, or NVIDIA runtime configuration.

gb10_find_cdi_spec() {
  local candidate
  for candidate in \
    /var/run/cdi/nvidia-container-toolkit.json \
    /etc/cdi/nvidia.yaml \
    /etc/cdi/nvidia-container-toolkit.yaml \
    /var/run/cdi/nvidia.yaml
  do
    [[ -r $candidate ]] || continue
    grep -Eq '("kind"[[:space:]]*:[[:space:]]*"nvidia.com/gpu"|kind:[[:space:]]*nvidia.com/gpu)' "$candidate" || continue
    grep -Eq '("name"[[:space:]]*:[[:space:]]*"all"|name:[[:space:]]*all)' "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

gb10_podman_usable() {
  command -v podman >/dev/null 2>&1 || return 1
  [[ $(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null) == true ]] || return 1
  gb10_find_cdi_spec >/dev/null 2>&1
}

gb10_docker_usable() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1
}

gb10_select_container_engine() {
  case ${GB10_CONTAINER_ENGINE:-auto} in
    auto)
      if gb10_podman_usable; then
        printf 'podman\n'
      elif gb10_docker_usable; then
        printf 'docker\n'
      else
        return 1
      fi
      ;;
    podman)
      gb10_podman_usable || return 1
      printf 'podman\n'
      ;;
    docker)
      gb10_docker_usable || return 1
      printf 'docker\n'
      ;;
    *)
      return 1
      ;;
  esac
}

gb10_container_exists() {
  local engine=$1
  local name=$2
  case $engine in
    podman) podman container exists "$name" ;;
    docker) docker container inspect "$name" >/dev/null 2>&1 ;;
    *) return 2 ;;
  esac
}

gb10_remove_container() {
  local engine=$1
  local name=$2
  "$engine" rm --force "$name" >/dev/null 2>&1 || true
}
