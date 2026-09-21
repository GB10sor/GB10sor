#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$repo_root"
fail() { printf 'verification failed: %s\n' "$*" >&2; exit 1; }

for command in jq rg shasum; do command -v "$command" >/dev/null || fail "missing command: $command"; done
jq empty model-profiles.json REPOSITORY-POLICY.json
[[ $(jq '.profiles | length' model-profiles.json) == 28 ]] || fail 'profile count changed'
jq -e --argjson expected 28 '.expectedProfiles == $expected' REPOSITORY-POLICY.json >/dev/null || fail 'policy count changed'
jq -e '
  [.profiles | to_entries[] | . as $entry |
    ($entry.key | test("^[a-z0-9][a-z0-9-]*$")) and
    ($entry.value.modelId | type == "string" and length > 2) and
    ($entry.value.modelRevision | test("^[a-f0-9]{40}$")) and
    ($entry.value.image | test("(?:@|^)sha256:[a-f0-9]{64}$")) and
    ($entry.value.deployment.nodes | IN(1,2,3,4,8)) and
    ($entry.value.deployment.shell == ("model-" + $entry.key)) and
    ($entry.value.deployment.command | startswith("nix develop path:.#model-" + $entry.key + " --command ./scripts/launch-model.sh qualify-and-serve")) and
    ($entry.value.deployment.launcher | test("^scripts/[a-z0-9-]+[.]sh$"))
  ] | all
' model-profiles.json >/dev/null || fail 'profile contract is incomplete'

while IFS= read -r launcher; do [[ -x $launcher ]] || fail "missing launcher: $launcher"; done < <(jq -r '.profiles[].deployment.launcher' model-profiles.json | sort -u)

if rg -i --quiet 'uncensored|[ao]bliterat|derisked|m[.]o[.]g[.]-sec|white[-_ ]hat|aeon-qwen38' \
  model-profiles.json benchmark-profiles benchmark-recipes docs/recipes; then
  fail 'restricted deployment material is present in the standard edition'
fi
[[ ! -e container-patches/blackfrost-glm53-trips ]] || \
  fail 'restricted Blackfrost runtime patches are present in the standard edition'

if rg --hidden --glob '!scripts/verify-release.sh' --glob '!SOURCE-SHA256SUMS' --glob '!.git/**'   --quiet --pcre2 -- '-----BEGIN (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY-----|(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}|\bhf_[A-Za-z0-9]{20,}\b|\bAKIA[0-9A-Z]{16}\b|\bsk-[A-Za-z0-9]{20,}\b' .; then
  fail 'possible credential or private key detected'
fi
if rg --hidden --glob '!scripts/verify-release.sh' --glob '!SOURCE-SHA256SUMS' --glob '!.git/**'   --quiet --pcre2 -- '/Users/[A-Za-z0-9._-]+/|/home/(?!gb10(?:/|$))[A-Za-z0-9._-]+/|/etc/mkultron/'; then
  fail 'personal or legacy account path detected'
fi
if find . -path './.git' -prune -o -type l -print | rg --quiet .; then fail 'symbolic links are not allowed'; fi
if find . -path './.git' -prune -o -type f   \( -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' -o -name '.env' \) -print | rg --quiet .; then
  fail 'secret-bearing file type detected'
fi

while IFS= read -r file; do bash -n "$file" || fail "shell syntax: $file"; done < <(find scripts -type f -name '*.sh' -o -name '*.command' | sort)
python3 -m compileall -q scripts tests
shasum -a 256 -c SOURCE-SHA256SUMS >/dev/null
printf 'release_verification=pass\nprofiles=28\nedition=%s\n' "$(jq -r .edition REPOSITORY-POLICY.json)"
