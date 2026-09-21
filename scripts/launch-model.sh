#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
registry=${GB10_MODEL_PROFILE_REGISTRY:-$repo_root/model-profiles.json}
profile=${GB10_MODEL_PROFILE:-}
action=${1:-}

die() { printf 'deployment launcher failed: %s\n' "$*" >&2; exit 1; }
[[ -n $profile ]] || die 'GB10_MODEL_PROFILE is unset; enter a model-* Nix shell'
[[ -r $registry ]] || die "profile registry is unreadable: $registry"
jq -e --arg id "$profile" '.profiles[$id] != null' "$registry" >/dev/null || die "unknown profile: $profile"

launcher=$(jq -er --arg id "$profile" '.profiles[$id].deployment.launcher' "$registry")
case "$launcher" in scripts/*.sh) ;; *) die "unsafe launcher path: $launcher" ;; esac
[[ -x "$repo_root/$launcher" ]] || die "launcher is missing or not executable: $launcher"

case "$action" in
  show)
    jq --arg id "$profile" '{profile:$id} + .profiles[$id]' "$registry"
    ;;
  command)
    jq -r --arg id "$profile" '.profiles[$id].deployment.command' "$registry"
    ;;
  preflight|bootstrap|stage-runtime|acceptance|qualify-and-serve|benchmark-only|qualify-benchmark-and-stop|serve|stop|candidate-qualify-and-serve)
    exec "$repo_root/$launcher" "$action"
    ;;
  *)
    die 'action must be show, command, preflight, bootstrap, stage-runtime, acceptance, qualify-and-serve, benchmark-only, qualify-benchmark-and-stop, serve, or stop'
    ;;
esac
