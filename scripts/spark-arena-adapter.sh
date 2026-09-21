#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'Spark Arena adapter failed: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/spark-arena-adapter.sh preflight|dry-run|benchmark|arena RECIPE [OUTPUT]

Targets an already-running, loopback-bound OpenAI-compatible endpoint. The
Spark Arena upload path is disabled unless GB10_ARENA_UPLOAD=1 is explicit.
EOF
  exit 2
}

action=${1:-}
recipe=${2:-}
output=${3:-}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
bounded_profile=${GB10_BENCHMARK_PROFILE:-$repo_root/benchmark-profiles/bounded-32k-v1.yaml}
benchmark_hosts=${GB10_BENCHMARK_HOSTS:-127.0.0.1}
benchmark_tp=${GB10_BENCHMARK_TP:-1}
benchmark_pp=${GB10_BENCHMARK_PP:-1}
benchmark_tokenizer=${GB10_BENCHMARK_TOKENIZER:-}
recipe_runtime=$(awk '$1 == "runtime:" { print $2; exit }' "$recipe")
compat_pythonpath=
if [[ $recipe_runtime == trtllm ]]; then
  compat_pythonpath="$repo_root/scripts/benchmark-compat/trtllm"
fi
sparkrun_revision=f0cab5c58f06d62bbb4f0df509c1b1f2dadc3cad
sparkrun_source="git+https://github.com/spark-arena/sparkrun.git@$sparkrun_revision"

[[ $action == preflight || $action == dry-run || $action == benchmark || $action == arena ]] || usage
[[ -n $recipe && -r $recipe ]] || die "recipe is unreadable: $recipe"
[[ -r $bounded_profile ]] || die "bounded benchmark profile is unreadable: $bounded_profile"
command -v uvx >/dev/null 2>&1 || die 'uvx is absent; enter the profile Nix shell'
grep -Fx 'recipe_version: "2"' "$recipe" >/dev/null || die 'Spark Arena requires a v2 recipe'
grep -Eq '^model_revision: [0-9a-f]{40}$' "$recipe" || die 'recipe lacks an exact model revision'
grep -Eq '^container: .+@sha256:[0-9a-f]{64}$' "$recipe" || die 'recipe container is not digest pinned'
[[ $benchmark_tp =~ ^[1-8]$ && $benchmark_pp =~ ^[1-8]$ ]] || die 'benchmark TP/PP must each be 1..8'
(( benchmark_tp * benchmark_pp <= 8 )) || die 'benchmark TP x PP exceeds eight Sparks'

benchmark_overrides=()
if [[ -n $benchmark_tokenizer ]]; then
  [[ $benchmark_tokenizer == /* && -d $benchmark_tokenizer ]] || \
    die "benchmark tokenizer must be an existing absolute directory: $benchmark_tokenizer"
  benchmark_overrides=(-b "tokenizer=$benchmark_tokenizer")
fi

run_sparkrun() {
  if [[ -n $compat_pythonpath ]]; then
    GB10_LLAMA_BENCHY_TRTLLM_COMPAT=1 \
      PYTHONPATH="$compat_pythonpath${PYTHONPATH:+:$PYTHONPATH}" \
      SPARKRUN_NO_TELEMETRY=1 uvx --from "$sparkrun_source" sparkrun "$@"
  else
    SPARKRUN_NO_TELEMETRY=1 uvx --from "$sparkrun_source" sparkrun "$@"
  fi
}

case "$action" in
  preflight)
    run_sparkrun recipe validate --strict "$recipe"
    ;;
  dry-run)
    run_sparkrun benchmark performance "$recipe" --skip-run --hosts "$benchmark_hosts" \
      --tp "$benchmark_tp" --pp "$benchmark_pp" \
      --profile "$bounded_profile" --framework llama-benchy \
      ${benchmark_overrides[@]+"${benchmark_overrides[@]}"} --dry-run
    ;;
  benchmark)
    [[ -n $output ]] || die 'benchmark requires an output YAML path'
    [[ $output == /* ]] || die 'benchmark output path must be absolute'
    install -d "$(dirname -- "$output")"
    run_sparkrun benchmark performance "$recipe" --skip-run --hosts "$benchmark_hosts" \
      --tp "$benchmark_tp" --pp "$benchmark_pp" \
      --profile "$bounded_profile" --framework llama-benchy \
      ${benchmark_overrides[@]+"${benchmark_overrides[@]}"} --fresh --output "$output"
    ;;
  arena)
    [[ ${GB10_ARENA_UPLOAD:-0} == 1 ]] || die 'set GB10_ARENA_UPLOAD=1 to authorize an external upload'
    [[ -n $output ]] || die 'arena requires an output YAML path'
    [[ $output == /* ]] || die 'arena output path must be absolute'
    install -d "$(dirname -- "$output")"
    run_sparkrun benchmark performance "$recipe" --skip-run --hosts "$benchmark_hosts" \
      --tp "$benchmark_tp" --pp "$benchmark_pp" \
      --profile @official/spark-arena-v2 --framework llama-benchy \
      ${benchmark_overrides[@]+"${benchmark_overrides[@]}"} --fresh --arena --output "$output"
    ;;
esac
