#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/uvx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'telemetry=%s\n' "${SPARKRUN_NO_TELEMETRY:-unset}" >>"$GB10_TEST_LOG"
printf 'trtllm_compat=%s\n' "${GB10_LLAMA_BENCHY_TRTLLM_COMPAT:-unset}" >>"$GB10_TEST_LOG"
printf 'pythonpath=%s\n' "${PYTHONPATH:-unset}" >>"$GB10_TEST_LOG"
printf '%s\n' "$*" >>"$GB10_TEST_LOG"
EOF
chmod +x "$tmp/bin/uvx"
export PATH="$tmp/bin:$PATH"
export GB10_TEST_LOG="$tmp/uvx.log"

recipe="$repo_root/benchmark-recipes/muse-glimmer-solo-vllm.yaml"
adapter="$repo_root/scripts/spark-arena-adapter.sh"
output="$tmp/result.yaml"

require_log() {
  grep -Fq -- "$1" "$GB10_TEST_LOG" || {
    printf 'FAIL: expected adapter argument was absent: %s\n' "$1" >&2
    cat "$GB10_TEST_LOG" >&2
    exit 1
  }
}

"$adapter" preflight "$recipe"
require_log 'telemetry=1'
require_log 'sparkrun recipe validate --strict'

: >"$GB10_TEST_LOG"
"$adapter" dry-run "$recipe"
require_log '--skip-run --hosts 127.0.0.1 --tp 1 --pp 1'
require_log '--framework llama-benchy --dry-run'

: >"$GB10_TEST_LOG"
GB10_BENCHMARK_HOSTS=192.0.2.1,192.0.2.2,192.0.2.3,192.0.2.4 \
  GB10_BENCHMARK_TP=4 GB10_BENCHMARK_PP=1 \
  "$adapter" dry-run "$recipe"
require_log '--skip-run --hosts 192.0.2.1,192.0.2.2,192.0.2.3,192.0.2.4 --tp 4 --pp 1'

: >"$GB10_TEST_LOG"
GB10_BENCHMARK_TOKENIZER="$tmp" "$adapter" dry-run "$recipe"
require_log "-b tokenizer=$tmp"

: >"$GB10_TEST_LOG"
trt_recipe="$repo_root/benchmark-recipes/nemotron-lightning-solo-trtllm-rc26.yaml"
"$adapter" dry-run "$trt_recipe"
require_log 'trtllm_compat=1'
require_log "pythonpath=$repo_root/scripts/benchmark-compat/trtllm"

mkdir -p "$tmp/fake/llama_benchy"
cat >"$tmp/fake/llama_benchy/__init__.py" <<'EOF'
EOF
cat >"$tmp/fake/llama_benchy/client.py" <<'EOF'
class LLMClient:
    def _build_generation_payload(self, messages, max_tokens, no_cache):
        return {"messages": messages, "max_tokens": max_tokens,
                "return_token_ids": True}
EOF
GB10_LLAMA_BENCHY_TRTLLM_COMPAT=1 \
  PYTHONPATH="$repo_root/scripts/benchmark-compat/trtllm:$tmp/fake" \
  python3 - <<'PY'
from llama_benchy.client import LLMClient
payload = LLMClient()._build_generation_payload([], 8, False)
assert "return_token_ids" not in payload
assert payload["max_tokens"] == 8
PY

if GB10_BENCHMARK_TOKENIZER="$tmp/missing" "$adapter" dry-run "$recipe" >/dev/null 2>&1; then
  printf 'FAIL: nonexistent offline tokenizer directory was accepted\n' >&2
  exit 1
fi

: >"$GB10_TEST_LOG"
if GB10_BENCHMARK_TP=4 GB10_BENCHMARK_PP=4 \
  "$adapter" dry-run "$recipe" >/dev/null 2>&1; then
  printf 'FAIL: benchmark TP x PP above eight was accepted\n' >&2
  exit 1
fi
[[ ! -s $GB10_TEST_LOG ]]

: >"$GB10_TEST_LOG"
if "$adapter" arena "$recipe" "$output" >/dev/null 2>&1; then
  printf 'FAIL: Arena upload was accepted without explicit authorization\n' >&2
  exit 1
fi
[[ ! -s $GB10_TEST_LOG ]]

if "$adapter" benchmark "$recipe" relative.yaml >/dev/null 2>&1; then
  printf 'FAIL: relative benchmark evidence path was accepted\n' >&2
  exit 1
fi

: >"$GB10_TEST_LOG"
"$adapter" benchmark "$recipe" "$output"
require_log '--fresh --output'
require_log "$output"

: >"$GB10_TEST_LOG"
GB10_ARENA_UPLOAD=1 "$adapter" arena "$recipe" "$output"
require_log '--fresh --arena --output'

sed '/^container:/d' "$recipe" >"$tmp/unpinned.yaml"
if "$adapter" preflight "$tmp/unpinned.yaml" >/dev/null 2>&1; then
  printf 'FAIL: recipe without digest-pinned container was accepted\n' >&2
  exit 1
fi

if GB10_MODEL_PROFILE=deepseek-v41-flash-quads-vllm-boot10-candidate300k \
  GB10_MODEL_PROFILE_REGISTRY="$repo_root/model-profiles.json" \
  "$repo_root/scripts/model-profile.sh" benchmark-only \
  >"$tmp/blocked.stdout" 2>"$tmp/blocked.stderr"; then
  printf 'FAIL: deployment-blocked profile entered the benchmark path\n' >&2
  exit 1
fi
grep -Fq 'benchmark is blocked for this profile' "$tmp/blocked.stderr"

printf 'PASS: Spark Arena adapter is pinned, local by default, and upload-gated\n'
