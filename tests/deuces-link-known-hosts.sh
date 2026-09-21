#!/usr/bin/env bash
set -Eeuo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -f "$fixture/known_hosts"; rmdir "$fixture"' EXIT
touch "$fixture/known_hosts"
unset DEUCES_SSH_IDENTITY_FILE
DEUCES_SSH_KNOWN_HOSTS_FILE="$fixture/known_hosts"
options_source=$(sed -n '/^ssh_options=(/,/^created_hosts=()/p' "$repo_root/scripts/deuces-link-smoke.sh" | sed '$d')
eval "$options_source"
printf '%s\n' "${ssh_options[@]}" | grep -Fxq StrictHostKeyChecking=yes
printf '%s\n' "${ssh_options[@]}" | grep -Fxq "UserKnownHostsFile=$fixture/known_hosts"
printf 'PASS: link smoke honors pinned known-hosts file and strict checking\n'
status=0
(DEUCES_SSH_KNOWN_HOSTS_FILE="$fixture/missing"; eval "$options_source") >/dev/null 2>&1 || status=$?
[[ "$status" == 2 ]]
printf 'PASS: missing pinned known-hosts file fails before remote work\n'
