#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
for scenario in idle autoconnect dhcp ssh-failure; do
  status=0
  (
    eval "$(sed -n '/^require_idle_autoconnect() {$/,/^}$/p' "$root/scripts/deuces-direct-model.sh")"
    arp_guard_interfaces=(enp1s0f0np0 enP2p1s0f0np0)
    nmcli() {
      if [[ "$2" == GENERAL.AUTOCONNECT ]]; then
        if [[ "$scenario" == autoconnect ]]; then printf 'yes\n'; else printf 'no\n'; fi
      else
        if [[ "$scenario" == dhcp ]]; then printf '70 (connecting (getting IP configuration))\n'; else printf '30 (disconnected)\n'; fi
      fi
    }
    # SSH executes a separate shell. An eval subshell inherits the caller's
    # conditional-errexit suppression on Bash 5 and can hide a failed check.
    export -f nmcli
    export scenario
    remote() { [[ "$scenario" != ssh-failure ]] || return 255; bash -c "$2"; }
    die() { exit 23; }
    require_idle_autoconnect fixture
  ) || status=$?
  if [[ "$scenario" == idle ]]; then [[ "$status" == 0 ]]; else [[ "$status" == 23 ]]; fi
  printf 'PASS direct autoconnect preflight: %s\n' "$scenario"
done
