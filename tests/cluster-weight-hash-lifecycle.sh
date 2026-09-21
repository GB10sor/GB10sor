#!/usr/bin/env bash
# Offline systemd adapter failure injection: no SSH, GPU, model, or system unit.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/gb10-hash-tests.XXXXXX")
token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
unit=gb10sor-vllm-quads-offline-weights-rank0
export token unit
stat() { if [[ "$1" == -c ]]; then id -u; else command stat "$@"; fi; }
readlink() { [[ "$1" == -f ]] && printf '%s\n' "$2"; }
flock() { return 0; }
findmnt() { if [[ "$*" == *SOURCE ]]; then echo /dev/nvme0n1p2; else printf '%s\n' "${filesystem:-ext4}"; fi; }
lsblk() { echo nvme0n1p2; }
systemd-run() { touch "$state/started"; }
mock_property() {
  case "$1" in
    LoadState)
      if [[ "$scenario" == collected && -e "$state/stopped" ]]; then echo not-found
      elif [[ -e "$state/started" || "$scenario" == collision ]]; then echo loaded; else echo not-found; fi;;
    Description) if [[ "$scenario" == foreign ]]; then echo foreign; else echo "GB10 owned weight hash $token"; fi;;
    KillMode) echo control-group;;
    ExecStart)
      local argv="/run/current-system/sw/bin/bash $state/hash.sh worker $state $unit $token /model $token"
      [[ "$scenario" != replaced-arguments ]] || argv="/run/current-system/sw/bin/bash $state/hash.sh worker $state $unit $token /other-model $token"
      [[ "$scenario" != extra-arguments ]] || argv+=" unexpected"
      if [[ "$scenario" == replaced-command ]]; then echo foreign
      else
        printf '{ path=/run/current-system/sw/bin/bash ; argv[]=%s ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }' "$argv"
        [[ "$scenario" != extra-command ]] || printf ' { path=/bin/false ; argv[]=/bin/false ; ignore_errors=no ; pid=0 }'
        printf '\n'
      fi;;
    SubState) if [[ -e "$state/stopped" ]]; then echo dead; elif [[ "$scenario" == timeout ]]; then echo failed; else echo exited; fi;;
    Result) if [[ "$scenario" == timeout || "$scenario" == replaced-result ]]; then echo timeout; else echo success; fi;;
    ExecMainStatus) echo 0;;
    MainPID) if [[ "$scenario" == live-pid ]]; then echo 321; else echo 0; fi;;
    ActiveState) echo inactive;;
    ControlGroup) if [[ "$scenario" == cleared && -e "$state/stopped" ]]; then echo ''; else echo "/user.slice/mock/$unit.service"; fi;;
    InvocationID)
      if [[ "$scenario" == replaced-invocation ]]; then echo cccccccccccccccccccccccccccccccc
      elif [[ "$scenario" == cleared && -e "$state/stopped" ]]; then echo ''
      else echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; fi;;
    *) echo 0;;
  esac
}
systemctl() {
  local operation=$2 arg property value count=0 properties=()
  if [[ "$operation" == stop ]]; then
    [[ "$scenario" != stop-failed ]] || return 1
    touch "$state/stopped"; return 0
  fi
  for arg in "$@"; do
    case "$arg" in LoadState|Description|KillMode|ExecStart|SubState|Result|ExecMainStatus|MainPID|ActiveState|ControlGroup|InvocationID|RuntimeMaxUSec) properties+=("$arg");; esac
  done
  for property in "${properties[@]}"; do
    value=$(mock_property "$property")
    if [[ "$*" == *--value* ]]; then printf '%s\n' "$value"; else printf '%s=%s\n' "$property" "$value"; fi
  done
}
export -f stat readlink flock findmnt lsblk systemd-run mock_property systemctl
new_case() {
  scenario=$1; state="$test_root/$scenario"; mkdir "$state"
  cp "$repo/scripts/cluster-weight-hash.sh" "$state/hash.sh"
  printf '%s\n' "$token" >"$state/owner"
  (cd "$state" && sha256sum hash.sh >helper.sha256)
  export scenario state
}
run() { bash "$state/hash.sh" "$1" "$state" "$unit" "$token" /model "$token" 60; }
record_attempt() {
  touch "$state/start-attempted" "$state/started"
  printf '%s\n' "/run/current-system/sw/bin/bash $state/hash.sh worker $state $unit $token /model $token" >"$state/expected-argv"
  (cd "$state" && sha256sum expected-argv >expected-argv.sha256)
}
expect_fail() { if run "$1"; then printf 'unexpected pass %s\n' "$scenario" >&2; exit 1; fi; }
new_case collision; expect_fail start; [[ ! -e "$state/started" ]]; echo 'PASS collision -> zero starts'
new_case cancelled; touch "$state/cancelled"; expect_fail start; [[ ! -e "$state/started" ]]; echo 'PASS cancellation tombstone -> zero starts'
new_case timeout; expect_fail start; [[ ! -e "$state/tree.sha256" ]]; echo 'PASS remote timeout never becomes hash pass'
new_case foreign; record_attempt; expect_fail stop; [[ ! -e "$state/stopped" ]]; echo 'PASS foreign identity never stopped'
new_case invocation; record_attempt; printf 'InvocationID=cccccccccccccccccccccccccccccccc\n' >"$state/identity.txt"; expect_fail stop; [[ ! -e "$state/stopped" ]]; echo 'PASS different invocation never stopped'
new_case never; run stop; [[ -e "$state/cancelled" && ! -e "$state/stopped" ]]; echo 'PASS stop before launch tombstones without touching another unit'
new_case owned; record_attempt; run stop; [[ -e "$state/stopped" ]]; echo 'PASS exact owned cancellation invokes control-group stop'
new_case pass; printf '%s\n' "$token" >"$state/tree.sha256"; run start; [[ -e "$state/started" && -e "$state/stopped" ]]; echo 'PASS sealed successful hash returned after immediate stop'
run stop; echo 'PASS repeated exact completed stop uses positive receipt'
new_case cleared; printf '%s\n' "$token" >"$state/tree.sha256"; run start; run stop; echo 'PASS cleared InvocationID after proven stop is idempotent'
new_case collected; printf '%s\n' "$token" >"$state/tree.sha256"; run start; run stop; echo 'PASS collected unit after proven stop is idempotent'
new_case missing-after-attempt; touch "$state/start-attempted"; expect_fail stop; echo 'PASS absent attempted unit without stop proof fails'
new_case missing-after-identity; printf 'InvocationID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$state/identity.txt"; expect_fail stop; echo 'PASS absent saved invocation without stop proof fails'
new_case stop-failed; record_attempt; expect_fail stop; [[ ! -e "$state/stop-proof.sha256" ]]; echo 'PASS failed stop cannot create success receipt'
new_case extra-arguments; record_attempt; expect_fail stop; [[ ! -e "$state/stopped" ]]; echo 'PASS extra worker argv rejected before stop'
new_case extra-command; record_attempt; expect_fail stop; [[ ! -e "$state/stopped" ]]; echo 'PASS additional ExecStart command rejected before stop'
new_case wrong-arguments; record_attempt; scenario=replaced-arguments; expect_fail stop; [[ ! -e "$state/stopped" ]]; echo 'PASS wrong model argv rejected before stop'
new_case missing-expected; touch "$state/started"; expect_fail stop; [[ ! -e "$state/stopped" ]]; echo 'PASS missing exact argv record rejected before stop'
new_case replace; printf '%s\n' "$token" >"$state/tree.sha256"; run start
scenario=replaced-invocation; expect_fail stop; echo 'PASS replaced invocation rejected after original stop'
scenario=replaced-command; expect_fail stop; echo 'PASS replaced command rejected after original stop'
scenario=replaced-arguments; expect_fail stop; echo 'PASS same-prefix changed arguments rejected after original stop'
scenario=foreign; expect_fail stop; echo 'PASS replaced Description rejected after original stop'
scenario=replaced-result; expect_fail stop; echo 'PASS changed result rejected after original stop'
scenario=live-pid; expect_fail stop; echo 'PASS nonzero PID rejected after original stop'
scenario=replace; printf 'changed\n' >>"$state/before-stop.txt"; expect_fail stop; echo 'PASS altered stop proof rejected'
new_case canceled-delayed; run stop; expect_fail start; [[ ! -e "$state/started" ]]; echo 'PASS cancel before start blocks delayed start'
# Exercise the exact cgroup reader with a test-only path substitution. No host
# cgroup is created, inspected or changed. Descendant content, not stat size,
# decides whether cleanup can pass.
group="/user.slice/mock/$unit.service"
mkdir -p "$test_root/cgroups$group/child"
printf '999\n' >"$test_root/cgroups$group/child/cgroup.procs"
fixture_code=$(sed -n '/^cgroup_empty() {/,/^}/p' "$repo/scripts/cluster-weight-hash.sh")
fixture_code=${fixture_code//\/sys\/fs\/cgroup/$test_root/cgroups}
eval "$fixture_code"
if cgroup_empty "$group"; then echo 'unexpected missing root procs pass' >&2; exit 1; fi
echo 'PASS missing root cgroup.procs rejected'
: >"$test_root/cgroups$group/cgroup.procs"
if cgroup_empty "$group"; then echo 'unexpected nonempty descendant pass' >&2; exit 1; fi
echo 'PASS nonempty descendant rejected by actual content reader'
: >"$test_root/cgroups$group/child/cgroup.procs"
cgroup_empty "$group"; echo 'PASS empty descendants accepted'
find() { return 1; }
if cgroup_empty "$group"; then echo 'unexpected failed descendant query pass' >&2; exit 1; fi
unset -f find
echo 'PASS failed descendant query propagated'
printf '123\n' >"$test_root/cgroups$group/cgroup.procs"
if cgroup_empty "$group"; then echo 'unexpected live root group pass' >&2; exit 1; fi
echo 'PASS nonempty root cgroup.procs rejected'
if cgroup_empty /user.slice/unrelated.service; then exit 1; fi
echo 'PASS foreign cgroup path rejected'
new_case tamper; printf '\n# modified\n' >>"$state/hash.sh"; expect_fail start; [[ ! -e "$state/started" ]]; echo 'PASS helper tampering -> zero starts'
new_case network; filesystem=nfs; export filesystem; expect_fail start; [[ ! -e "$state/started" ]]; echo 'PASS remote filesystem -> zero starts'
unset filesystem
for inherited_mask in 022 002 000; do
  new_case "private-$inherited_mask"
  printf '%s\n' "$token" >"$state/tree.sha256"
  (umask "$inherited_mask"; run start)
  python3 -I -B - "$repo" "$state" <<'PY'
import importlib.util,pathlib,sys,stat
repo,root=map(pathlib.Path,sys.argv[1:])
spec=importlib.util.spec_from_file_location('S',repo/'scripts/deuces-direct-state.py')
S=importlib.util.module_from_spec(spec);spec.loader.exec_module(S)
names=['expected-argv','expected-argv.sha256','start-attempted','identity.txt',
       'before-stop.txt','after-stop.txt','stop.receipt','stop-proof.sha256','cancelled','control.lock']
for name in names:
    p=root/name
    assert stat.S_IMODE(p.stat().st_mode)==0o600,(name,oct(p.stat().st_mode))
    S.read_file(p)
original=(root/'stop-proof.sha256').read_bytes()
# A bad pre-existing receipt must remain rejected; the reader is not relaxed.
(root/'stop-proof.sha256').chmod(0o644)
try:S.read_file(root/'stop-proof.sha256')
except RuntimeError:pass
else:raise AssertionError('public receipt accepted')
assert (root/'stop-proof.sha256').read_bytes()==original
PY
  run stop
  python3 -I -B - "$state/stop-proof.sha256" <<'PY'
import pathlib,stat,sys
assert stat.S_IMODE(pathlib.Path(sys.argv[1]).stat().st_mode)==0o644
PY
  echo "PASS ambient $inherited_mask -> actual private reader; old mode not repaired"
done
printf 'Offline evidence retained at %s\n' "$test_root"
