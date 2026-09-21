#!/usr/bin/env bash
# Exact, bounded, per-run remote weight hashing. Invoked only after the caller
# creates a private ownership directory and seals this script there.
set -Eeuo pipefail
# Every invocation (including the independent worker and repeated stop) creates
# private receipts, irrespective of the caller or user manager's ambient mask.
# Existing evidence is never chmod'ed or repaired in place.
umask 077
action=$1 state=$2 unit=$3 token=$4
[[ "$state" =~ ^/[A-Za-z0-9._/-]+$ && "$unit" =~ ^gb10sor-vllm-[a-zA-Z0-9-]+-weights-rank[0-7]$ ]] || exit 1
[[ "$token" =~ ^[a-f0-9]{64}$ && -d "$state" && ! -L "$state" ]] || exit 1
[[ $(stat -c %u "$state") == "$(id -u)" ]] || exit 1
[[ $(cat "$state/owner") == "$token" ]] || exit 1
self=$(readlink -f "${BASH_SOURCE[0]}")
[[ "$self" == "$state/hash.sh" ]] || exit 1
(cd "$state" && sha256sum --strict -c helper.sha256 >/dev/null)
description="GB10 owned weight hash $token"

verify_unit_static() {
  local observed expected pattern
  [[ $(systemctl --user show "$unit.service" -p Description --value) == "$description" ]] || return 1
  [[ $(systemctl --user show "$unit.service" -p KillMode --value) == control-group ]] || return 1
  [[ -f "$state/expected-argv" && -f "$state/expected-argv.sha256" ]] || return 1
  (cd "$state" && sha256sum --strict -c expected-argv.sha256 >/dev/null) || return 1
  expected=$(cat "$state/expected-argv") || return 1
  observed=$(systemctl --user show "$unit.service" -p ExecStart --value) || return 1
  # The validated arguments contain no whitespace/semicolon/brace characters.
  # Parse exactly one systemd ExecStart record, not a substring permitting extra
  # argv or additional commands. Time/PID/status metadata may legitimately vary.
  pattern='^\{ path=([^;]+) ; argv\[\]=([^;]+) ; ignore_errors=no ; ([^{}]*) \}$'
  [[ "$observed" =~ $pattern ]] || return 1
  [[ "${BASH_REMATCH[1]}" == /run/current-system/sw/bin/bash && "${BASH_REMATCH[2]}" == "$expected" ]] || return 1
}
verify_unit() {
  verify_unit_static || return 1
  if [[ -f "$state/identity.txt" ]]; then
    saved_invocation=$(sed -n 's/^InvocationID=//p' "$state/identity.txt")
    [[ "$saved_invocation" =~ ^[a-f0-9]{32}$ ]] || return 1
    [[ $(systemctl --user show "$unit.service" -p InvocationID --value) == "$saved_invocation" ]] || return 1
  fi
}

cgroup_empty() {
  local group=$1
  [[ "$group" == /user.slice/* && "$group" == */"$unit.service" && "$group" != *..* ]] || return 1
  if [[ -e "/sys/fs/cgroup$group" ]]; then
    [[ -d "/sys/fs/cgroup$group" && ! -L "/sys/fs/cgroup$group" ]] || return 1
    [[ -f "/sys/fs/cgroup$group/cgroup.procs" && -r "/sys/fs/cgroup$group/cgroup.procs" && ! -L "/sys/fs/cgroup$group/cgroup.procs" ]] || return 1
    # cgroup.procs is a pseudo-file: stat size zero does not prove emptiness.
    local contents
    contents=$(cat "/sys/fs/cgroup$group/cgroup.procs") || return 1
    [[ -z "$contents" ]] || return 1
    contents=$(find "/sys/fs/cgroup$group" -name cgroup.procs -exec cat {} +) || return 1
    [[ -z "$contents" ]] || return 1
  fi
}

verify_stopped() {
  local invocation=$1 group=$2 load live_invocation current_group active sub
  [[ "$invocation" =~ ^[a-f0-9]{32}$ ]] || return 1
  cgroup_empty "$group" || return 1
  load=$(systemctl --user show "$unit.service" -p LoadState --value) || return 1
  case "$load" in
    not-found) return 0;; # Allowed only after a proven stop, never by itself.
    loaded) ;;
    *) return 1;;
  esac
  verify_unit_static || return 1
  [[ $(systemctl --user show "$unit.service" -p MainPID --value) == 0 ]] || return 1
  active=$(systemctl --user show "$unit.service" -p ActiveState --value) || return 1
  sub=$(systemctl --user show "$unit.service" -p SubState --value) || return 1
  [[ "$active/$sub" == inactive/dead || "$active/$sub" == failed/failed ]] || return 1
  live_invocation=$(systemctl --user show "$unit.service" -p InvocationID --value) || return 1
  [[ -z "$live_invocation" || "$live_invocation" == "$invocation" ]] || return 1
  current_group=$(systemctl --user show "$unit.service" -p ControlGroup --value) || return 1
  [[ -z "$current_group" || "$current_group" == "$group" ]] || return 1
}

verify_stop_receipt() {
  local invocation group load
  [[ -f "$state/stop-proof.sha256" && ! -L "$state/stop-proof.sha256" ]] || return 1
  (cd "$state" && sha256sum --strict -c stop-proof.sha256 >/dev/null) || return 1
  [[ $(sed -n '1p' "$state/stop.receipt") == "$token" ]] || return 1
  [[ $(sed -n '2p' "$state/stop.receipt") == "$unit" ]] || return 1
  invocation=$(sed -n '3p' "$state/stop.receipt")
  group=$(sed -n '4p' "$state/stop.receipt")
  [[ $(sed -n '5p' "$state/stop.receipt") == owned-unit-stopped-empty ]] || return 1
  [[ $(sed -n 's/^InvocationID=//p' "$state/before-stop.txt") == "$invocation" ]] || return 1
  if [[ -f "$state/identity.txt" ]]; then
    [[ $(sed -n 's/^InvocationID=//p' "$state/identity.txt") == "$invocation" ]] || return 1
  fi
  verify_stopped "$invocation" "$group" || return 1
  load=$(systemctl --user show "$unit.service" -p LoadState --value) || return 1
  if [[ "$load" == loaded ]]; then
    [[ $(systemctl --user show "$unit.service" -p ExecStart --value) == "$(sed -n 's/^ExecStart=//p' "$state/before-stop.txt")" ]] || return 1
    [[ $(systemctl --user show "$unit.service" -p Result --value) == "$(sed -n 's/^Result=//p' "$state/after-stop.txt")" ]] || return 1
    [[ $(systemctl --user show "$unit.service" -p ExecMainStatus --value) == "$(sed -n 's/^ExecMainStatus=//p' "$state/after-stop.txt")" ]] || return 1
  fi
}

case "$action" in
  start)
    model=$5 expected=$6 seconds=$7 storage_mode=${8:-local-nvme} shared_source=${9:-}
    [[ "$model" =~ ^/[A-Za-z0-9._/@+-]+$ && "$expected" =~ ^[a-f0-9]{64}$ ]] || exit 1
    [[ "$seconds" =~ ^[0-9]+$ ]] && (( seconds >= 60 && seconds <= 7200 )) || exit 1
    [[ ! -L "$model" && $(readlink -f "$model") == "$model" ]] || exit 1
    case "$storage_mode" in
      local-nvme)
        [[ -z "$shared_source" ]] || exit 1
        fstype=$(findmnt -T "$model" -rn -o FSTYPE | tail -n 1)
        device=$(findmnt -T "$model" -rn -o SOURCE | tail -n 1)
        case "$fstype" in ext4|xfs|btrfs) ;; *) exit 1;; esac
        device=${device%%\[*}
        [[ "$device" == /dev/* ]] || exit 1
        lsblk -s -n -o NAME "$device" | grep -Eq '(^|[^a-zA-Z0-9])nvme[0-9]+n[0-9]+' || exit 1
        ;;
      read-only-shared)
        # A systemd automount reports both its autofs control layer and the
        # backing NFS mount. Select the backing filesystem explicitly so a
        # valid read-only automount cannot become a two-line false failure.
        fstype=$(findmnt -T "$model" -t nfs,nfs4 -rn -o FSTYPE | tail -n 1)
        device=$(findmnt -T "$model" -t nfs,nfs4 -rn -o SOURCE | tail -n 1)
        [[ "$shared_source" =~ ^[A-Za-z0-9._:/@+-]+$ && "$device" == "$shared_source" ]] || exit 1
        case "$fstype" in nfs|nfs4) ;; *) exit 1;; esac
        mount_options=$(findmnt -T "$model" -t nfs,nfs4 -rn -o OPTIONS | tail -n 1)
        case ",$mount_options," in *,ro,*) ;; *) exit 1;; esac
        ;;
      *) exit 1 ;;
    esac
    exec 9>"$state/control.lock"; flock -x 9
    [[ ! -e "$state/cancelled" ]] || exit 1
    [[ ! -e "$state/start-attempted" && ! -e "$state/identity.txt" && ! -e "$state/expected-argv" ]] || exit 1
    [[ $(systemctl --user show "$unit.service" -p LoadState --value) == not-found ]] || exit 1
    printf '%s\n' "/run/current-system/sw/bin/bash $self worker $state $unit $token $model $expected" >"$state/expected-argv"
    (cd "$state" && sha256sum expected-argv >expected-argv.sha256)
    touch "$state/start-attempted"
    systemd-run --user --unit="$unit" --description="$description" \
      --property=Type=exec --property=RemainAfterExit=yes \
      --property="RuntimeMaxSec=$seconds" --property=TimeoutStopSec=15 \
      --property=KillMode=control-group --property="StandardOutput=append:$state/stdout" \
      --property="StandardError=append:$state/stderr" \
      /run/current-system/sw/bin/bash "$self" worker "$state" "$unit" "$token" "$model" "$expected" >&2
    verify_unit || exit 1
    systemctl --user show "$unit.service" -p InvocationID -p ExecStart -p MainPID -p ControlGroup \
      -p RuntimeMaxUSec -p KillMode >"$state/identity.txt"
    flock -u 9
    # RuntimeMax is enforced remotely even if the SSH/coordinator disappears.
    for ((elapsed=0; elapsed<=seconds+30; elapsed+=2)); do
      sub=$(systemctl --user show "$unit.service" -p SubState --value)
      case "$sub" in
        exited)
          [[ $(systemctl --user show "$unit.service" -p Result --value) == success && -f "$state/tree.sha256" ]] || exit 1
          verified=$(cat "$state/tree.sha256")
          # Stop promptly after success; do not retain an active-exited unit
          # through subsequent model startup/serving.
          bash "$self" stop "$state" "$unit" "$token" >&2
          printf '%s\n' "$verified"
          exit 0;;
        failed|dead) systemctl --user show "$unit.service" -p Result -p ExecMainStatus >&2; exit 1;;
      esac
      sleep 2
    done
    exit 1
    ;;
  worker)
    model=$5 expected=$6
    cd "$model"
    # Reject symlinked weights and detect any metadata/size/path change during
    # hashing. Exact content still must match the pinned expected full-tree hash.
    [[ -z $(find . -type l -name '*.safetensors' -print -quit) ]] || exit 1
    find . -type f -name '*.safetensors' -printf '%p %s %T@ %C@\n' | LC_ALL=C sort >"$state/metadata.before"
    find . -type f -name '*.safetensors' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}' >"$state/tree.candidate"
    find . -type f -name '*.safetensors' -printf '%p %s %T@ %C@\n' | LC_ALL=C sort >"$state/metadata.after"
    cmp "$state/metadata.before" "$state/metadata.after"
    [[ $(cat "$state/tree.candidate") == "$expected" ]] || exit 1
    cp "$state/tree.candidate" "$state/tree.sha256"
    ;;
  stop)
    exec 9>"$state/control.lock"; flock -x 9
    # Tombstone prevents a delayed start after cancellation. Never remove state.
    touch "$state/cancelled"
    if [[ -e "$state/stop-proof.sha256" ]]; then
      verify_stop_receipt || exit 1
      printf 'owned-unit-already-stopped-empty\n'; exit 0
    fi
    if [[ $(systemctl --user show "$unit.service" -p LoadState --value) == not-found ]]; then
      [[ ! -e "$state/start-attempted" && ! -e "$state/identity.txt" && ! -e "$state/before-stop.txt" ]] || exit 1
      printf 'never-started\n'; exit 0
    fi
    verify_unit || exit 1
    invocation=$(systemctl --user show "$unit.service" -p InvocationID --value)
    [[ "$invocation" =~ ^[a-f0-9]{32}$ ]] || exit 1
    group=$(systemctl --user show "$unit.service" -p ControlGroup --value)
    if [[ -z "$group" && -f "$state/identity.txt" ]]; then
      group=$(sed -n 's/^ControlGroup=//p' "$state/identity.txt")
    fi
    if [[ -z "$group" ]]; then
      # A very small checkpoint can finish before the first systemctl show.
      # systemd may already have removed its empty cgroup.  Derive the exact
      # default app.slice path only for a successfully exited, identity-checked
      # owned unit whose hash receipt was written, then prove it is empty.
      [[ $(systemctl --user show "$unit.service" -p Slice --value) == app.slice ]] || exit 1
      [[ $(systemctl --user show "$unit.service" -p SubState --value) == exited ]] || exit 1
      [[ $(systemctl --user show "$unit.service" -p Result --value) == success ]] || exit 1
      [[ $(systemctl --user show "$unit.service" -p ExecMainStatus --value) == 0 ]] || exit 1
      [[ $(systemctl --user show "$unit.service" -p MainPID --value) == 0 ]] || exit 1
      [[ -f "$state/tree.sha256" && $(cat "$state/tree.sha256") == $(cat "$state/tree.candidate") ]] || exit 1
      uid=$(id -u)
      group="/user.slice/user-$uid.slice/user@$uid.service/app.slice/$unit.service"
    fi
    [[ "$group" == /user.slice/* && "$group" == */"$unit.service" && "$group" != *..* ]] || exit 1
    systemctl --user show "$unit.service" -p InvocationID -p Description -p ExecStart -p KillMode \
      -p Result -p ExecMainStatus -p MainPID -p ControlGroup >"$state/before-stop.txt"
    [[ $(sed -n 's/^InvocationID=//p' "$state/before-stop.txt") == "$invocation" ]] || exit 1
    systemctl --user stop "$unit.service"
    verify_stopped "$invocation" "$group" || exit 1
    systemctl --user show "$unit.service" -p LoadState -p InvocationID -p Result -p ExecMainStatus \
      -p ActiveState -p SubState -p MainPID -p ControlGroup >"$state/after-stop.txt"
    printf '%s\n' "$token" "$unit" "$invocation" "$group" owned-unit-stopped-empty >"$state/stop.receipt"
    (cd "$state" && sha256sum before-stop.txt after-stop.txt stop.receipt expected-argv expected-argv.sha256 >stop-proof.sha256.tmp)
    mv "$state/stop-proof.sha256.tmp" "$state/stop-proof.sha256"
    printf 'owned-unit-stopped-empty\n'
    ;;
  *) exit 2;;
esac
