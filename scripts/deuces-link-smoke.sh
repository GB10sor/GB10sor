#!/usr/bin/env bash
set -Eeuo pipefail

# Non-destructive two-node direct-fabric qualification. The script creates
# in-memory NetworkManager profiles, never changes saved profiles, and removes
# only the exact UUIDs it created. Raw output is private by default.

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf 'missing required environment variable: %s\n' "$name" >&2
    exit 2
  fi
}

for name in \
  DEUCES_LEFT_HOST DEUCES_RIGHT_HOST \
  DEUCES_LEFT_RAIL_A DEUCES_RIGHT_RAIL_A
do
  require_env "$name"
done

interface_count="${DEUCES_DIRECT_INTERFACE_COUNT:-2}"
[[ "$interface_count" == 1 || "$interface_count" == 2 ]] || {
  printf 'DEUCES_DIRECT_INTERFACE_COUNT must be 1 or 2\n' >&2
  exit 2
}
if [[ "$interface_count" == 2 ]]; then
  require_env DEUCES_LEFT_RAIL_B
  require_env DEUCES_RIGHT_RAIL_B
fi

left_host="$DEUCES_LEFT_HOST"
right_host="$DEUCES_RIGHT_HOST"
left_rail_a_cidr="$DEUCES_LEFT_RAIL_A"
right_rail_a_cidr="$DEUCES_RIGHT_RAIL_A"
left_rail_b_cidr="${DEUCES_LEFT_RAIL_B:-}"
right_rail_b_cidr="${DEUCES_RIGHT_RAIL_B:-}"

rail_a_interface="${DEUCES_RAIL_A_INTERFACE:-enp1s0f0np0}"
rail_b_interface="${DEUCES_RAIL_B_INTERFACE:-enP2p1s0f0np0}"
expected_speed_mbps="${DEUCES_EXPECTED_SPEED_MBPS:-200000}"
iperf_seconds="${DEUCES_IPERF_SECONDS:-5}"
iperf_streams="${DEUCES_IPERF_STREAMS:-4}"
target_mtu="${DEUCES_MTU:-1500}"
df_payload_bytes="${DEUCES_DF_PAYLOAD_BYTES:-$((target_mtu - 28))}"
allow_temporary_firewall="${DEUCES_ALLOW_TEMPORARY_FIREWALL:-0}"
minimum_single_rail_gbps="${DEUCES_MIN_SINGLE_RAIL_GBPS:-40}"
minimum_dual_aggregate_gbps="${DEUCES_MIN_DUAL_AGGREGATE_GBPS:-80}"
perftest_bin="${DEUCES_PERFTEST_BIN:-}"
perftest_version="${DEUCES_PERFTEST_VERSION:-6.29}"
rdma_seconds="${DEUCES_RDMA_SECONDS:-10}"
minimum_rdma_rail_gbps="${DEUCES_MIN_RDMA_RAIL_GBPS:-80}"
minimum_rdma_dual_gbps="${DEUCES_MIN_RDMA_DUAL_GBPS:-160}"
collective_runner="${DEUCES_COLLECTIVE_RUNNER:-}"
payload_runner="${DEUCES_PAYLOAD_RUNNER:-}"
preconfigured="${DEUCES_LINK_PRECONFIGURED:-0}"
[[ "$preconfigured" == 0 || "$preconfigured" == 1 ]] || {
  printf 'DEUCES_LINK_PRECONFIGURED must be 0 or 1\n' >&2
  exit 2
}

# Candidate owned lifecycle is deliberately explicit and single-port. It must
# never fall back to PID-only servers or create a second network/firewall owner.
owned_link_mode="${GB10_DEUCES_OWNED_LIFECYCLE:-0}"
[[ "$owned_link_mode" == 0 || "$owned_link_mode" == 1 ]] || exit 2
link_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
iperf_bin="${DEUCES_IPERF_BIN:-iperf3}"
if [[ "$owned_link_mode" == 1 ]]; then
  [[ "$preconfigured" == 1 && "$interface_count" == 1 && "$allow_temporary_firewall" == 0 ]] || {
    printf 'owned link tests require one parent-configured port and parent-owned firewall\n' >&2
    exit 2
  }
  for name in DEUCES_LINK_SERVER_PLAN DEUCES_LINK_SERVER_PLAN_SHA256 \
    DEUCES_SSH_IDENTITY_FILE DEUCES_SSH_KNOWN_HOSTS_FILE DEUCES_IPERF_BIN DEUCES_LEFT_NODE DEUCES_RIGHT_NODE; do
    require_env "$name"
  done
  [[ "$iperf_bin" =~ ^/nix/store/[a-z0-9]+-[A-Za-z0-9._+-]+/bin/iperf3$ ]] || exit 2
  expected_server_labels=(rail-a-left-to-right rail-a-right-to-left
    rail-a-left-to-right-client rail-a-right-to-left-client)
  if [[ -n "$perftest_bin" ]]; then
    expected_server_labels+=(rdma-a-left-to-right rdma-a-right-to-left
      rdma-a-left-to-right-client rdma-a-right-to-left-client)
  fi
  python3 "$link_script_dir/deuces-link-server-transport.py" check-pair \
    "$DEUCES_LINK_SERVER_PLAN" "$DEUCES_LINK_SERVER_PLAN_SHA256" "$left_host" "$DEUCES_LEFT_NODE" \
    "$right_host" "$DEUCES_RIGHT_NODE" "${expected_server_labels[@]}" >/dev/null
fi

left_rail_a="${left_rail_a_cidr%/*}"
right_rail_a="${right_rail_a_cidr%/*}"
left_rail_b="${left_rail_b_cidr%/*}"
right_rail_b="${right_rail_b_cidr%/*}"
fabric_interfaces=("$rail_a_interface")
if [[ "$interface_count" == 2 ]]; then
  fabric_interfaces+=("$rail_b_interface")
fi

run_id="gb10sor-deuces-$(date -u +%Y%m%dT%H%M%SZ)-$$"
if [[ -n "${DEUCES_EVIDENCE_DIR:-}" ]]; then
  evidence_dir="$DEUCES_EVIDENCE_DIR"
  mkdir -p "$evidence_dir"
else
  evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/gb10sor-deuces.XXXXXX")"
fi

ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)
if [[ -n "${DEUCES_SSH_IDENTITY_FILE:-}" ]]; then
  [[ -f "$DEUCES_SSH_IDENTITY_FILE" ]] || {
    printf 'DEUCES_SSH_IDENTITY_FILE is not a readable file: %s\n' \
      "$DEUCES_SSH_IDENTITY_FILE" >&2
    exit 2
  }
  ssh_options+=(
    -o IdentitiesOnly=yes
    -i "$DEUCES_SSH_IDENTITY_FILE"
  )
fi

if [[ -n "${DEUCES_SSH_KNOWN_HOSTS_FILE:-}" ]]; then
  [[ -r "$DEUCES_SSH_KNOWN_HOSTS_FILE" ]] || {
    printf 'DEUCES_SSH_KNOWN_HOSTS_FILE is not readable: %s\n' \
      "$DEUCES_SSH_KNOWN_HOSTS_FILE" >&2
    exit 2
  }
  ssh_options+=(
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$DEUCES_SSH_KNOWN_HOSTS_FILE"
  )
fi

created_hosts=()
created_uuids=()
created_names=()
created_interfaces=()
created_cidrs=()
server_hosts=()
server_pids=()
owned_link_hosts=()
owned_link_labels=()
firewall_hosts=()
firewall_rules=()
baseline_hosts=()
baseline_interfaces=()
baseline_connections=()
baseline_mtus=()
baseline_arp_ignores=()
baseline_arp_announces=()

remote() {
  local host="$1"
  shift
  [[ $# == 1 ]] || return 2
  # The controller may run on a Mac or another management host.  A matching
  # target string is not sufficient proof that the left Spark is local; only
  # bypass SSH when the controller hostname is the declared left node.
  if [[ -n "${DEUCES_LEFT_NODE:-}" && "$(hostname -s)" == "$DEUCES_LEFT_NODE" && "$host" == "$DEUCES_LEFT_HOST" ]]; then
    /run/current-system/sw/bin/bash --noprofile --norc -euo pipefail -c "$1"
    return
  fi
  local quoted
  printf -v quoted '%q' "$1"
  ssh "${ssh_options[@]}" "$host" "/run/current-system/sw/bin/bash --noprofile --norc -euo pipefail -c $quoted"
}

owned_link_call() {
  local action=$1 host=$2 label=$3 receipt_dir
  shift 3
  [[ "$label" =~ ^[a-z][a-z0-9-]{0,79}$ ]] || return 2
  receipt_dir=$(mktemp -d "$evidence_dir/owned-link-$label-$action.XXXXXX") || return
  python3 "$link_script_dir/deuces-link-server-transport.py" "$action" \
    "$DEUCES_LINK_SERVER_PLAN" "$DEUCES_LINK_SERVER_PLAN_SHA256" "$host" "$label" \
    "$receipt_dir" "$DEUCES_SSH_IDENTITY_FILE" "$DEUCES_SSH_KNOWN_HOSTS_FILE" "$@"
}

start_owned_link_server() {
  local host=$1 label=$2
  shift 2
  # Register BEFORE prepare; even an ambiguous prepare/start reply is owned.
  owned_link_hosts+=("$host")
  owned_link_labels+=("$label")
  owned_link_call prepare "$host" "$label" >/dev/null || return
  owned_link_call start "$host" "$label" "$@" >/dev/null
}

stop_owned_link_servers() {
  local index failed=0
  for ((index=${#owned_link_labels[@]}-1; index>=0; index--)); do
    owned_link_call stop "${owned_link_hosts[$index]}" "${owned_link_labels[$index]}" >/dev/null || failed=1
  done
  (( failed == 0 )) || return 1
  owned_link_hosts=()
  owned_link_labels=()
}

run_owned_link_client() {
  local host=$1 label=$2 output=$3 status=0 journal_status=0
  shift 3
  # Clients use the same finite service ownership as servers. A natural exit
  # and usable journal are separate requirements; cleanup never changes either.
  start_owned_link_server "$host" "$label" "$@" || status=$?
  if (( status == 0 )); then
    owned_link_call wait-success "$host" "$label" >/dev/null || status=$?
  fi
  owned_link_call journal "$host" "$label" >"$output.journal-receipt.json" || journal_status=$?
  (( status == 0 )) || return "$status"
  (( journal_status == 0 )) || return "$journal_status"
  jq -er '.text | select(type == "string" and length > 0)' \
    "$output.journal-receipt.json" >"$output"
}

remove_owned_profile() {
  local host=$1 uuid=$2 name=$3 interface=$4 cidr=$5
  remote "$host" "set -euo pipefail
    existing=\$(nmcli -g UUID connection show)
    if printf '%s\\n' \"\$existing\" | grep -Fxq '$uuid'; then
      found_name=\$(nmcli -g connection.id connection show uuid '$uuid')
      found_interface=\$(nmcli -g connection.interface-name connection show uuid '$uuid')
      found_address=\$(nmcli -g ipv4.addresses connection show uuid '$uuid')
      test \"\$found_name\" = '$name'
      test \"\$found_interface\" = '$interface'
      test \"\$found_address\" = '$cidr'
      active=\$(nmcli -g GENERAL.CON-UUID device show '$interface')
      case \"\$active\" in
        '$uuid') sudo -n nmcli --wait 10 connection down uuid '$uuid' >/dev/null ;;
        ''|'--') ;;
        *) echo 'Refusing cleanup: unexpected active connection' >&2; exit 1 ;;
      esac
      sudo -n nmcli connection delete uuid '$uuid' >/dev/null
    fi
    after=\$(nmcli -g UUID connection show)
    if printf '%s\\n' \"\$after\" | grep -Fxq '$uuid'; then exit 1; fi
    active_after=\$(nmcli -g GENERAL.CON-UUID device show '$interface')
    case \"\$active_after\" in ''|'--') ;; *) exit 1 ;; esac"
}

restore_fabric_baseline() {
  local host=$1 interface=$2 mtu=$3 arp_ignore=$4 arp_announce=$5
  remote "$host" "set -euo pipefail
    active=\$(nmcli -g GENERAL.CON-UUID device show '$interface')
    case \"\$active\" in ''|'--') ;; *) echo 'Refusing restoration over an active connection' >&2; exit 1 ;; esac
    sudo -n ip link set '$interface' mtu '$mtu'
    sudo -n sysctl -qw 'net.ipv4.conf.$interface.arp_ignore=$arp_ignore'
    sudo -n sysctl -qw 'net.ipv4.conf.$interface.arp_announce=$arp_announce'
    restored_mtu=\$(cat '/sys/class/net/$interface/mtu')
    restored_ignore=\$(sysctl -n 'net.ipv4.conf.$interface.arp_ignore')
    restored_announce=\$(sysctl -n 'net.ipv4.conf.$interface.arp_announce')
    test \"\$restored_mtu\" = '$mtu'
    test \"\$restored_ignore\" = '$arp_ignore'
    test \"\$restored_announce\" = '$arp_announce'"
}

cleanup() (
  local index host uuid pid failed=0
  set +e

  if [[ "${owned_link_mode:-0}" == 1 ]]; then
    stop_owned_link_servers || {
      printf 'link cleanup failed: owned server cleanup uncertain; network restoration skipped\n' >&2
      return 1
    }
  fi

  for ((index = 0; index < ${#server_pids[@]}; index++)); do
    host="${server_hosts[$index]}"
    pid="${server_pids[$index]}"
    remote "$host" "if sudo -n kill -0 '$pid' 2>/dev/null; then sudo -n kill '$pid'; fi" \
      >/dev/null 2>&1 || true
  done

  # An ambiguous insert reply still has a recorded ownership tuple. Remove the
  # exact rule and verify its absence before changing the underlying network.
  for ((index = ${#firewall_rules[@]} - 1; index >= 0; index--)); do
    remove_temporary_firewall_rule "${firewall_hosts[$index]}" \
      "${firewall_rules[$index]}" || failed=1
  done
  if (( failed )); then
    printf 'link cleanup failed: firewall removal uncertain; restoration skipped\n' >&2
    return 1
  fi

  # Remove only verified owned profiles before considering baseline changes.
  # A failed query/removal must not be hidden by a later successful operation.
  for ((index = ${#created_uuids[@]} - 1; index >= 0; index--)); do
    remove_owned_profile "${created_hosts[$index]}" "${created_uuids[$index]}" \
      "${created_names[$index]}" "${created_interfaces[$index]}" "${created_cidrs[$index]}" || failed=1
  done
  if (( failed )); then
    printf 'link cleanup failed: profile identity/removal uncertain; restoration skipped\n' >&2
    return 1
  fi

  for ((index = 0; index < ${#baseline_connections[@]}; index++)); do
    host="${baseline_hosts[$index]}"
    interface="${baseline_interfaces[$index]}"
    restore_fabric_baseline "$host" "$interface" "${baseline_mtus[$index]}" \
      "${baseline_arp_ignores[$index]}" "${baseline_arp_announces[$index]}" || failed=1
  done

  (( failed == 0 ))
)
trap 'original_status=$?; trap - EXIT; cleanup || exit 1; exit "$original_status"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

connection_inventory() {
  local host="$1"
  remote "$host" \
    "nmcli -t -f NAME,UUID,TYPE,AUTOCONNECT connection show | LC_ALL=C sort"
}

active_connection_inventory() {
  local host="$1"
  remote "$host" \
    "nmcli -t -f NAME,UUID,TYPE,DEVICE connection show --active | LC_ALL=C sort"
}

record_fabric_baseline() {
  local host="$1"
  local interface connection mtu arp_ignore arp_announce
  if [[ "${preconfigured:-0}" == 1 ]]; then
    require_preconfigured_fabric "$host" "$rail_a_interface" || return
    [[ "$interface_count" == 1 ]] || require_preconfigured_fabric "$host" "$rail_b_interface" || return
    preconfigured_route_inventory "$host" >"$evidence_dir/$host-preconfigured-routes-before.json" || return
    return 0  # Parent owns restoration; do not register another network owner.
  fi
  for interface in "${fabric_interfaces[@]}"; do
    connection="$(remote "$host" "nmcli -g GENERAL.CON-UUID device show '$interface'")"
    # Qualification starts from reviewed direct-idle state. Do not replace or
    # later reactivate somebody else's saved/active connection by name.
    case "$connection" in
      ''|'--') ;;
      *) printf 'link test requires an inactive direct interface: %s/%s\n' "$host" "$interface" >&2; return 1 ;;
    esac
    mtu="$(remote "$host" "cat '/sys/class/net/$interface/mtu'")"
    arp_ignore="$(remote "$host" "sysctl -n 'net.ipv4.conf.$interface.arp_ignore'")"
    arp_announce="$(remote "$host" "sysctl -n 'net.ipv4.conf.$interface.arp_announce'")"
    baseline_hosts+=("$host")
    baseline_interfaces+=("$interface")
    baseline_connections+=("$connection")
    baseline_mtus+=("$mtu")
    baseline_arp_ignores+=("$arp_ignore")
    baseline_arp_announces+=("$arp_announce")
  done
}

require_preconfigured_fabric() {
  local host=$1 interface=$2 side rail cidr uuid
  case "$host" in
    "$left_host") side=LEFT ;;
    "$right_host") side=RIGHT ;;
    *) return 2 ;;
  esac
  case "$interface" in
    "$rail_a_interface") rail=A ;;
    "$rail_b_interface") [[ "$interface_count" == 2 ]] || return 2; rail=B ;;
    *) return 2 ;;
  esac
  local cidr_variable="DEUCES_${side}_RAIL_${rail}"
  local uuid_variable="DEUCES_LINK_${side}_UUID_${rail}"
  cidr=${!cidr_variable:-}; uuid=${!uuid_variable:-}
  [[ "$interface" =~ ^[A-Za-z0-9_.:-]+$ && "$cidr" =~ ^[0-9.]+/[0-9]+$ &&
     "$target_mtu" =~ ^[0-9]+$ && "$uuid" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || return 2
  remote "$host" "set -euo pipefail
    active=\$(nmcli -g GENERAL.CON-UUID device show '$interface')
    test \"\$active\" = '$uuid'
    bound=\$(nmcli -g connection.interface-name connection show uuid '$uuid')
    test \"\$bound\" = '$interface'
    configured=\$(nmcli -g ipv4.addresses connection show uuid '$uuid')
    test \"\$configured\" = '$cidr'
    addresses=\$(ip -o -4 address show dev '$interface')
    actual_cidrs=\$(printf '%s\\n' \"\$addresses\" | awk '{print \$4}')
    test \"\$actual_cidrs\" = '$cidr'
    ipv6=\$(ip -o -6 address show dev '$interface')
    test -z \"\$ipv6\"
    mtu=\$(cat /sys/class/net/$interface/mtu)
    test \"\$mtu\" = '$target_mtu'
    ignore=\$(sysctl -n net.ipv4.conf.$interface.arp_ignore)
    announce=\$(sysctl -n net.ipv4.conf.$interface.arp_announce)
    test \"\$ignore\" = 1
    test \"\$announce\" = 2"
}

# Preconfigured profiles remain parent-owned. Preserve exact selected routes
# across traffic; querying all tables avoids iproute2 device-filter omissions.
preconfigured_route_inventory() {
  local host=$1 ipv4 ipv6
  [[ "$host" == "$left_host" || "$host" == "$right_host" ]] || return 2
  ipv4=$(remote "$host" "ip -j -4 route show table all") || return
  ipv6=$(remote "$host" "ip -j -6 route show table all") || return
  jq -cnS --argjson ipv4 "$ipv4" --argjson ipv6 "$ipv6" \
    --arg a "$rail_a_interface" --arg b "$rail_b_interface" --arg count "$interface_count" '
    if (($ipv4|type) != "array" or ($ipv6|type) != "array" or
        ($ipv4|all(.[]; type=="object")|not) or ($ipv6|all(.[]; type=="object")|not))
    then error("route object arrays required") else
      {ipv4:($ipv4|map(select(.dev==$a or ($count=="2" and .dev==$b)))|sort_by(tojson)),
       ipv6:($ipv6|map(select(.dev==$a or ($count=="2" and .dev==$b)))|sort_by(tojson))}
    end'
}

require_preconfigured_address_ownership() {
  local host=$1 interface=$2 own peer rows
  require_preconfigured_fabric "$host" "$interface" || return
  if [[ "$host" == "$left_host" ]]; then
    if [[ "$interface" == "$rail_a_interface" ]]; then own=$left_rail_a_cidr; peer=$right_rail_a_cidr
    else own=$left_rail_b_cidr; peer=$right_rail_b_cidr; fi
  elif [[ "$host" == "$right_host" ]]; then
    if [[ "$interface" == "$rail_a_interface" ]]; then own=$right_rail_a_cidr; peer=$left_rail_a_cidr
    else own=$right_rail_b_cidr; peer=$left_rail_b_cidr; fi
  else return 2; fi
  rows=$(remote "$host" "ip -j -4 address show") || return
  # Full inventory proves the peer IP is absent everywhere and the own IP is
  # present exactly once, on this NIC with its exact prefix. The profile
  # observer above separately rejects any additional selected-NIC address.
  jq -e --arg own "${own%/*}" --arg peer "${peer%/*}" --arg dev "$interface" \
    --argjson prefix "${own#*/}" '
    if type!="array" then error("address array required") else
    [.[] as $link | $link.addr_info[] |
      select(.family=="inet" and (.local==$own or .local==$peer)) |
      {dev:$link.ifname,local:.local,prefixlen:.prefixlen}]
      == [{dev:$dev,local:$own,prefixlen:$prefix}] end' <<<"$rows" >/dev/null
}

verify_postflight_addresses() {
  local host=$1
  if [[ "$preconfigured" == 1 ]]; then
    require_preconfigured_address_ownership "$host" "$rail_a_interface" || return
    [[ "$interface_count" == 1 ]] || require_preconfigured_address_ownership "$host" "$rail_b_interface" || return
    preconfigured_route_inventory "$host" >"$evidence_dir/$host-preconfigured-routes-after.json" || return
    diff -u "$evidence_dir/$host-preconfigured-routes-before.json" \
      "$evidence_dir/$host-preconfigured-routes-after.json" || return
    return 0
  fi
  # Legacy transient-owned mode keeps its existing all-addresses-absent check.
  remote "$host" \
    "! ip -o address show | grep -F '$left_rail_a_cidr'
     ! ip -o address show | grep -F '$right_rail_a_cidr'" || return
  if [[ "$interface_count" == 2 ]]; then
    remote "$host" \
      "! ip -o address show | grep -F '$left_rail_b_cidr'
       ! ip -o address show | grep -F '$right_rail_b_cidr'" || return
  fi
}

fabric_runtime_inventory() {
  local host="$1"
  local interfaces="'$rail_a_interface'"
  [[ "$interface_count" == 1 ]] || interfaces+=" '$rail_b_interface'"
  remote "$host" "for interface in $interfaces; do
    printf '%s mtu=' \"\$interface\"
    cat \"/sys/class/net/\$interface/mtu\"
    printf ' arp_ignore='
    sysctl -n \"net.ipv4.conf.\$interface.arp_ignore\"
    printf ' arp_announce='
    sysctl -n \"net.ipv4.conf.\$interface.arp_announce\"
  done"
}

default_routes() {
  local host="$1"
  remote "$host" "ip -j route show default"
}

error_counters() {
  local host="$1"
  local interfaces="'$rail_a_interface'"
  [[ "$interface_count" == 1 ]] || interfaces+=" '$rail_b_interface'"
  remote "$host" "for interface in $interfaces; do
    printf '%s ' \"\$interface\"
    for counter in rx_errors tx_errors rx_dropped tx_dropped; do
      cat \"/sys/class/net/\$interface/statistics/\$counter\"
    done | tr '\\n' ' '
    printf '\\n'
  done"
}

firewall_inventory() {
  local host="$1"
  remote "$host" "sudo -n iptables -S"
}

verify_parent_link_rule() {
  local host=$1 interface=$2 peer=$3 expected comment rule
  [[ "${GB10_DEUCES_PARENT_FIREWALL:-0}" == 1 && "$owned_link_mode" == 1 &&
     "$preconfigured" == 1 && "$interface_count" == 1 && "$allow_temporary_firewall" == 0 &&
     "${GB10_DEUCES_NETWORK_OWNER:-}" =~ ^[a-f0-9]{64}$ && "$interface" == "$rail_a_interface" ]] || return 2
  if [[ "$host" == "$left_host" ]]; then expected=$right_rail_a
  elif [[ "$host" == "$right_host" ]]; then expected=$left_rail_a
  else return 2; fi
  [[ "$peer" == "$expected" && "$peer" =~ ^[0-9.]+$ && "$interface" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 2
  comment="gb10sor-direct-link-$GB10_DEUCES_NETWORK_OWNER"
  rule="-i '$interface' -s '$peer' -p tcp --dport 5211:5324 -m comment --comment '$comment' -j nixos-fw-accept"
  remote "$host" "set -euo pipefail
    rules=\$(sudo -n iptables -w 5 -S nixos-fw)
    test \"\$(printf '%s\\n' \"\$rules\" | grep -F -c -- '$comment')\" = 1
    sudo -n iptables -w 5 -C nixos-fw $rule" || return 1
  printf '%s\t%s\t%s\t%s\n' "$host" "$interface" "$peer" "$comment" >>"$evidence_dir/firewall-parent-observation.tsv"
}

add_temporary_firewall_rule() {
  local host="$1"
  local interface="$2"
  local peer="$3"
  local rule

  [[ "$interface" =~ ^[A-Za-z0-9_.:-]+$ && "$peer" =~ ^[0-9.]+$ &&
     "$run_id" =~ ^gb10sor-deuces-[A-Za-z0-9-]+$ ]] || return 2
  rule="-i '$interface' -s '$peer' -p tcp --dport 5211:5324 -m comment --comment '$run_id' -j nixos-fw-accept"
  # A successful inventory is required; query errors are never treated as an
  # absent rule. Exact pre-existing rules are not adopted by this invocation.
  remote "$host" "sudo -n iptables -w 5 -S nixos-fw >/dev/null
    if sudo -n iptables -w 5 -C nixos-fw $rule; then exit 1
    else status=\$?; test \"\$status\" = 1; fi" || return 1
  firewall_hosts+=("$host")
  firewall_rules+=("$rule")
  remote "$host" "sudo -n iptables -w 5 -I nixos-fw 1 $rule
    sudo -n iptables -w 5 -C nixos-fw $rule"
}

remove_temporary_firewall_rule() {
  local host=$1 rule=$2
  remote "$host" "sudo -n iptables -w 5 -S nixos-fw >/dev/null
    if sudo -n iptables -w 5 -C nixos-fw $rule; then
      sudo -n iptables -w 5 -D nixos-fw $rule
    else status=\$?; test \"\$status\" = 1; fi
    sudo -n iptables -w 5 -S nixos-fw >/dev/null
    if sudo -n iptables -w 5 -C nixos-fw $rule; then exit 1
    else status=\$?; test \"\$status\" = 1; fi"
}

physical_gate() {
  local host="$1"
  local interface
  for interface in "${fabric_interfaces[@]}"; do
    remote "$host" \
      "test \"\$(cat '/sys/class/net/$interface/operstate')\" = up
       ethtool '$interface' | grep -F 'Speed: ${expected_speed_mbps}Mb/s'
       ethtool '$interface' | grep -F 'Link detected: yes'
       sudo -n ethtool --show-fec '$interface' | grep -F 'Active FEC encoding: RS'
       rdma link show | grep -F 'netdev $interface' | grep -F 'state ACTIVE' | grep -F 'physical_state LINK_UP'" \
      >>"$evidence_dir/physical.txt"
  done
}

add_profile() {
  local host="$1"
  local name="$2"
  local interface="$3"
  local cidr="$4"
  local uuid
  uuid=$(python3 -c 'import uuid; print(uuid.uuid4())')
  [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || return 1
  remote "$host" "set -e; existing=\$(nmcli -g UUID connection show); if printf '%s\\n' \"\$existing\" | grep -Fxq '$uuid'; then exit 1; fi"
  # Register the requested identity before a mutation whose reply may be lost.
  created_hosts+=("$host")
  created_uuids+=("$uuid")
  created_names+=("$name")
  created_interfaces+=("$interface")
  created_cidrs+=("$cidr")
  remote "$host" \
    "sudo -n nmcli connection add save no type ethernet ifname '$interface' con-name '$name' connection.uuid '$uuid' connection.autoconnect no 802-3-ethernet.mtu '$target_mtu' ipv4.method manual ipv4.addresses '$cidr' ipv4.never-default yes ipv4.ignore-auto-dns yes ipv6.method disabled >/dev/null" \
    2>>"$evidence_dir/networkmanager-warnings.txt"
  remote "$host" "set -e; test \"\$(nmcli -g connection.uuid connection show uuid '$uuid')\" = '$uuid'; test \"\$(nmcli -g connection.interface-name connection show uuid '$uuid')\" = '$interface'; test \"\$(nmcli -g connection.id connection show uuid '$uuid')\" = '$name'"
  remote "$host" \
    "sudo -n nmcli --wait 20 connection up uuid '$uuid' >/dev/null" \
    2>>"$evidence_dir/networkmanager-warnings.txt"
}

route_and_ping_gate() {
  local host="$1"
  local interface="$2"
  local peer="$3"
  local source="$4"

  remote "$host" \
    "ip route get '$peer' | grep -F 'dev $interface' | grep -F 'src $source'
     ping -I '$interface' -M do -s '$df_payload_bytes' -c 5 -W 2 '$peer'" \
    >>"$evidence_dir/ip-mtu.txt"
}

tune_fabric_runtime() {
  local host="$1"
  local interface="$2"
  remote "$host" \
    "sudo -n ip link set '$interface' mtu '$target_mtu'
     sudo -n sysctl -qw 'net.ipv4.conf.$interface.arp_ignore=1'
     sudo -n sysctl -qw 'net.ipv4.conf.$interface.arp_announce=2'
     test \"\$(cat '/sys/class/net/$interface/mtu')\" = '$target_mtu'"
}

start_iperf_server() {
  local host="$1"
  local bind_address="$2"
  local port="$3"
  local label="$4"
  if [[ "${owned_link_mode:-0}" == 1 ]]; then
    start_owned_link_server "$host" "$label" "$iperf_bin" -s -1 -B "$bind_address" -p "$port"
    return
  fi
  local remote_log="/tmp/$run_id-$label-server.log"
  local pid

  pid="$(remote "$host" \
    "nohup iperf3 -s -1 -B '$bind_address' -p '$port' >'$remote_log' 2>&1 </dev/null & echo \$!")"
  server_hosts+=("$host")
  server_pids+=("$pid")
}

run_iperf_client() {
  local client_host="$1"
  local source_address="$2"
  local server_address="$3"
  local port="$4"
  local label="$5"

  if [[ "${owned_link_mode:-0}" == 1 ]]; then
    run_owned_link_client "$client_host" "$label-client" "$evidence_dir/$label.json" \
      "$iperf_bin" -c "$server_address" -B "$source_address" -p "$port" \
      -t "$iperf_seconds" -P "$iperf_streams" -J || return
  else
    remote "$client_host" \
    "timeout --signal=TERM --kill-after=2 '$((iperf_seconds + 15))' iperf3 -c '$server_address' -B '$source_address' -p '$port' -t '$iperf_seconds' -P '$iperf_streams' -J" \
    >"$evidence_dir/$label.json"
  fi
  jq -e \
    '.error == null and .end.sum_received.bits_per_second > 0 and .end.sum_sent.bits_per_second > 0' \
    "$evidence_dir/$label.json" >/dev/null
}

run_iperf() {
  local server_host="$1"
  local server_address="$2"
  local client_host="$3"
  local source_address="$4"
  local port="$5"
  local label="$6"

  start_iperf_server "$server_host" "$server_address" "$port" "$label"
  sleep 1
  run_iperf_client \
    "$client_host" "$source_address" "$server_address" "$port" "$label"
}

ipv4_gid() {
  local address="$1"
  local a b c d
  IFS=. read -r a b c d <<<"$address"
  printf '0000:0000:0000:0000:0000:ffff:%02x%02x:%02x%02x\n' \
    "$a" "$b" "$c" "$d"
}

resolve_rdma_device() {
  local host="$1"
  local interface="$2"
  local address="$3"
  local expected_gid resolved device index observed_gid normalized_expected normalized_observed
  expected_gid="$(ipv4_gid "$address")"
  resolved="$(remote "$host" "for device_path in /sys/class/infiniband/*; do
    for ndev_path in \"\$device_path\"/ports/1/gid_attrs/ndevs/*; do
      index=\"\${ndev_path##*/}\"
      if [[ \"\$(cat \"\$ndev_path\" 2>/dev/null)\" == '$interface' ]] \
        && [[ \"\$(cat \"\$device_path/ports/1/gid_attrs/types/\$index\" 2>/dev/null)\" == 'RoCE v2' ]]; then
        printf '%s %s %s\\n' \"\${device_path##*/}\" \"\$index\" \"\$(cat \"\$device_path/ports/1/gids/\$index\")\"
      fi
    done
  done" | tail -n 1)"
  read -r device index observed_gid <<<"$resolved"
  normalized_expected="$(printf '%s' "$expected_gid" | tr '[:upper:]' '[:lower:]')"
  normalized_observed="$(printf '%s' "$observed_gid" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$device" && -n "$index" && "$normalized_observed" == "$normalized_expected" ]] || {
    printf 'RoCE v2 GID mismatch on %s/%s: expected %s, observed %s\n' \
      "$host" "$interface" "$expected_gid" "${observed_gid:-none}" >&2
    return 1
  }
  printf '%s %s %s\n' "$device" "$index" "$observed_gid"
}

start_rdma_server() {
  local host="$1"
  local device="$2"
  local gid_index="$3"
  local port="$4"
  local label="$5"
  if [[ "${owned_link_mode:-0}" == 1 ]]; then
    start_owned_link_server "$host" "$label" "$perftest_bin" -d "$device" -F \
      -D "$rdma_seconds" -x "$gid_index" -s 1048576 -p "$port"
    return
  fi
  local remote_log="/tmp/$run_id-$label-server.log"
  local remote_pidfile="/tmp/$run_id-$label-server.pid"
  local pid

  remote "$host" \
    "rm -f '$remote_pidfile'; nohup sudo -n sh -c 'echo \$\$ >\"$remote_pidfile\"; exec timeout --signal=TERM --kill-after=5 $((rdma_seconds + 30)) prlimit --memlock=unlimited -- $perftest_bin -d $device -F -D $rdma_seconds -x $gid_index -s 1048576 -p $port' >'$remote_log' 2>&1 </dev/null &"
  for _ in $(seq 1 20); do
    pid="$(remote "$host" "cat '$remote_pidfile' 2>/dev/null || true")"
    [[ -n "$pid" ]] && break
    sleep 0.25
  done
  [[ -n "$pid" ]] || {
    printf 'RDMA server did not publish a PID for %s\n' "$label" >&2
    return 1
  }
  server_hosts+=("$host")
  server_pids+=("$pid")
}

run_rdma_client() {
  local host="$1"
  local device="$2"
  local gid_index="$3"
  local peer="$4"
  local port="$5"
  local label="$6"

  if [[ "${owned_link_mode:-0}" == 1 ]]; then
    run_owned_link_client "$host" "$label-client" "$evidence_dir/$label.txt" \
      "$perftest_bin" -d "$device" -F -D "$rdma_seconds" -x "$gid_index" \
      -s 1048576 -p "$port" "$peer"
    return
  fi
  remote "$host" \
    "sudo -n timeout --signal=TERM --kill-after=5 '$((rdma_seconds + 30))' prlimit --memlock=unlimited -- '$perftest_bin' -d '$device' -F -D '$rdma_seconds' -x '$gid_index' -s 1048576 -p '$port' '$peer'" \
    >"$evidence_dir/$label.txt"
}

rdma_gbps() {
  local file="$1"
  # perftest reports BW average in MiB/s. Convert it to decimal Gb/s before
  # applying thresholds or writing the machine-readable summary.
  awk '$1 ~ /^[0-9]+$/ && NF >= 5 { value=$4 } END {
    if (value == "") exit 1
    printf "%.6f\n", value * 8 * 1024 * 1024 / 1000000000
  }' "$file"
}

run_rdma() {
  local server_host="$1"
  local server_device="$2"
  local server_gid="$3"
  local client_host="$4"
  local client_device="$5"
  local client_gid="$6"
  local server_address="$7"
  local port="$8"
  local label="$9"

  start_rdma_server "$server_host" "$server_device" "$server_gid" "$port" "$label"
  sleep 2
  run_rdma_client "$client_host" "$client_device" "$client_gid" "$server_address" "$port" "$label"
  awk -v observed="$(rdma_gbps "$evidence_dir/$label.txt")" -v minimum="$minimum_rdma_rail_gbps" \
    'BEGIN { exit !(observed >= minimum) }'
}

compare_counters() {
  local before="$1"
  local after="$2"
  paste "$before" "$after" | awk '
    $1 != $6 { print "interface order changed: " $1 " != " $6 > "/dev/stderr"; exit 1 }
    $7 > $2 || $8 > $3 || $9 > $4 || $10 > $5 {
      print "link error/drop counter increased on " $1 > "/dev/stderr"; exit 1
    }
  '
}

for host in "$left_host" "$right_host"; do
  remote "$host" "sudo -n true"
  connection_inventory "$host" >"$evidence_dir/$host-connections-before.txt"
  active_connection_inventory "$host" >"$evidence_dir/$host-active-before.txt"
  default_routes "$host" >"$evidence_dir/$host-default-routes-before.json"
  error_counters "$host" >"$evidence_dir/$host-counters-before.txt"
  firewall_inventory "$host" >"$evidence_dir/$host-firewall-before.txt"
  fabric_runtime_inventory "$host" >"$evidence_dir/$host-runtime-before.txt"
  physical_gate "$host"
  record_fabric_baseline "$host"
done

if [[ "$preconfigured" == 0 ]]; then
add_profile "$left_host" "$run_id-left-a" "$rail_a_interface" "$left_rail_a_cidr"
add_profile "$right_host" "$run_id-right-a" "$rail_a_interface" "$right_rail_a_cidr"
if [[ "$interface_count" == 2 ]]; then
  add_profile "$left_host" "$run_id-left-b" "$rail_b_interface" "$left_rail_b_cidr"
  add_profile "$right_host" "$run_id-right-b" "$rail_b_interface" "$right_rail_b_cidr"
fi

tune_fabric_runtime "$left_host" "$rail_a_interface"
tune_fabric_runtime "$right_host" "$rail_a_interface"
if [[ "$interface_count" == 2 ]]; then
  tune_fabric_runtime "$left_host" "$rail_b_interface"
  tune_fabric_runtime "$right_host" "$rail_b_interface"
fi
fi

route_and_ping_gate "$left_host" "$rail_a_interface" "$right_rail_a" "$left_rail_a"
route_and_ping_gate "$right_host" "$rail_a_interface" "$left_rail_a" "$right_rail_a"
if [[ "$interface_count" == 2 ]]; then
  route_and_ping_gate "$left_host" "$rail_b_interface" "$right_rail_b" "$left_rail_b"
  route_and_ping_gate "$right_host" "$rail_b_interface" "$left_rail_b" "$right_rail_b"
fi

[[ "${GB10_DEUCES_PARENT_FIREWALL:-0}" == 0 || "${GB10_DEUCES_PARENT_FIREWALL:-0}" == 1 ]] || exit 2
if [[ "${GB10_DEUCES_PARENT_FIREWALL:-0}" == 1 ]]; then
  verify_parent_link_rule "$left_host" "$rail_a_interface" "$right_rail_a"
  verify_parent_link_rule "$right_host" "$rail_a_interface" "$left_rail_a"
elif [[ "$allow_temporary_firewall" == 1 ]]; then
  add_temporary_firewall_rule "$left_host" "$rail_a_interface" "$right_rail_a"
  add_temporary_firewall_rule "$right_host" "$rail_a_interface" "$left_rail_a"
  if [[ "$interface_count" == 2 ]]; then
    add_temporary_firewall_rule "$left_host" "$rail_b_interface" "$right_rail_b"
    add_temporary_firewall_rule "$right_host" "$rail_b_interface" "$left_rail_b"
  fi
fi

run_iperf "$right_host" "$right_rail_a" "$left_host" "$left_rail_a" 5211 rail-a-left-to-right
run_iperf "$left_host" "$left_rail_a" "$right_host" "$right_rail_a" 5212 rail-a-right-to-left
if [[ "$interface_count" == 2 ]]; then
  run_iperf "$right_host" "$right_rail_b" "$left_host" "$left_rail_b" 5213 rail-b-left-to-right
  run_iperf "$left_host" "$left_rail_b" "$right_host" "$right_rail_b" 5214 rail-b-right-to-left

  # Exercise both logical interfaces concurrently only in the explicit two-interface mode.
  start_iperf_server "$right_host" "$right_rail_a" 5221 dual-left-to-right-a
  start_iperf_server "$right_host" "$right_rail_b" 5222 dual-left-to-right-b
  sleep 1
  run_iperf_client "$left_host" "$left_rail_a" "$right_rail_a" 5221 dual-left-to-right-a &
  dual_a_pid=$!
  run_iperf_client "$left_host" "$left_rail_b" "$right_rail_b" 5222 dual-left-to-right-b &
  dual_b_pid=$!
  wait "$dual_a_pid"
  wait "$dual_b_pid"
fi

if [[ -n "$perftest_bin" ]]; then
  for host in "$left_host" "$right_host"; do
    remote "$host" \
      "test -x '$perftest_bin'; ('$perftest_bin' --version 2>&1 || true) | grep -Fx 'Version: $perftest_version'"
  done >"$evidence_dir/perftest-version.txt"

  read -r left_a_device left_a_gid _ <<<"$(resolve_rdma_device "$left_host" "$rail_a_interface" "$left_rail_a")"
  read -r right_a_device right_a_gid _ <<<"$(resolve_rdma_device "$right_host" "$rail_a_interface" "$right_rail_a")"
  rdma_values=("$left_a_device" "$left_a_gid" "$right_a_device" "$right_a_gid")
  if [[ "$interface_count" == 2 ]]; then
    read -r left_b_device left_b_gid _ <<<"$(resolve_rdma_device "$left_host" "$rail_b_interface" "$left_rail_b")"
    read -r right_b_device right_b_gid _ <<<"$(resolve_rdma_device "$right_host" "$rail_b_interface" "$right_rail_b")"
    rdma_values+=("$left_b_device" "$left_b_gid" "$right_b_device" "$right_b_gid")
  fi
  for value in "${rdma_values[@]}"; do
    [[ -n "$value" ]] || {
      printf 'failed to resolve an IPv4 RoCE v2 device/GID mapping\n' >&2
      exit 1
    }
  done
  printf '%s\n' \
    "left-a $left_a_device $left_a_gid" \
    "right-a $right_a_device $right_a_gid" \
    >"$evidence_dir/rdma-device-map.txt"
  if [[ "$interface_count" == 2 ]]; then
    printf '%s\n' \
      "left-b $left_b_device $left_b_gid" \
      "right-b $right_b_device $right_b_gid" \
      >>"$evidence_dir/rdma-device-map.txt"
  fi

  run_rdma "$right_host" "$right_a_device" "$right_a_gid" "$left_host" "$left_a_device" "$left_a_gid" "$right_rail_a" 5311 rdma-a-left-to-right
  run_rdma "$left_host" "$left_a_device" "$left_a_gid" "$right_host" "$right_a_device" "$right_a_gid" "$left_rail_a" 5312 rdma-a-right-to-left
  rdma_a_lr="$(rdma_gbps "$evidence_dir/rdma-a-left-to-right.txt")"
  rdma_a_rl="$(rdma_gbps "$evidence_dir/rdma-a-right-to-left.txt")"
  awk -v a="$rdma_a_lr" -v b="$rdma_a_rl" -v minimum="$minimum_rdma_rail_gbps" \
    'BEGIN { exit !(a >= minimum && b >= minimum) }'
  if [[ "$interface_count" == 2 ]]; then
    run_rdma "$right_host" "$right_b_device" "$right_b_gid" "$left_host" "$left_b_device" "$left_b_gid" "$right_rail_b" 5313 rdma-b-left-to-right
    run_rdma "$left_host" "$left_b_device" "$left_b_gid" "$right_host" "$right_b_device" "$right_b_gid" "$left_rail_b" 5314 rdma-b-right-to-left
    rdma_b_lr="$(rdma_gbps "$evidence_dir/rdma-b-left-to-right.txt")"
    rdma_b_rl="$(rdma_gbps "$evidence_dir/rdma-b-right-to-left.txt")"
    awk -v a="$rdma_b_lr" -v b="$rdma_b_rl" -v minimum="$minimum_rdma_rail_gbps" \
      'BEGIN { exit !(a >= minimum && b >= minimum) }'
  else
    rdma_b_lr=null
    rdma_b_rl=null
  fi

  jq -n \
    --argjson rail_a_left_to_right "$rdma_a_lr" \
    --argjson rail_a_right_to_left "$rdma_a_rl" \
    --argjson rail_b_left_to_right "$rdma_b_lr" \
    --argjson rail_b_right_to_left "$rdma_b_rl" \
    '{unit:"Gb/s",rail_a_left_to_right:$rail_a_left_to_right,rail_a_right_to_left:$rail_a_right_to_left,rail_b_left_to_right:$rail_b_left_to_right,rail_b_right_to_left:$rail_b_right_to_left}' \
    >"$evidence_dir/rdma-summary.json"
fi

if [[ "$owned_link_mode" == 1 ]]; then
  # One-port owned link traffic ends before potentially long model work. Never
  # extend or renew the finite server leases to cover a model serving session.
  stop_owned_link_servers
fi

if [[ -n "$payload_runner" ]]; then
  test -x "$payload_runner"
  DEUCES_LEFT_HOST="$left_host" \
  DEUCES_RIGHT_HOST="$right_host" \
  DEUCES_LEFT_RAIL_A="$left_rail_a_cidr" \
  DEUCES_RIGHT_RAIL_A="$right_rail_a_cidr" \
  DEUCES_LEFT_RAIL_B="$left_rail_b_cidr" \
  DEUCES_RIGHT_RAIL_B="$right_rail_b_cidr" \
  DEUCES_RAIL_A_INTERFACE="$rail_a_interface" \
  DEUCES_RAIL_B_INTERFACE="$rail_b_interface" \
  DEUCES_PAYLOAD_EVIDENCE_DIR="$evidence_dir/payload" \
    "$payload_runner"
fi

if [[ -n "$collective_runner" ]]; then
  test -x "$collective_runner"
  DEUCES_LEFT_HOST="$left_host" \
  DEUCES_RIGHT_HOST="$right_host" \
  DEUCES_LEFT_RAIL_A="$left_rail_a_cidr" \
  DEUCES_RIGHT_RAIL_A="$right_rail_a_cidr" \
  DEUCES_LEFT_RAIL_B="$left_rail_b_cidr" \
  DEUCES_RIGHT_RAIL_B="$right_rail_b_cidr" \
  DEUCES_RAIL_A_INTERFACE="$rail_a_interface" \
  DEUCES_RAIL_B_INTERFACE="$rail_b_interface" \
  DEUCES_COLLECTIVE_EVIDENCE_DIR="$evidence_dir/collective" \
    "$collective_runner"
fi

if [[ "$interface_count" == 2 ]]; then
  start_iperf_server "$left_host" "$left_rail_a" 5223 dual-right-to-left-a
  start_iperf_server "$left_host" "$left_rail_b" 5224 dual-right-to-left-b
  sleep 1
  run_iperf_client "$right_host" "$right_rail_a" "$left_rail_a" 5223 dual-right-to-left-a &
  dual_a_pid=$!
  run_iperf_client "$right_host" "$right_rail_b" "$left_rail_b" 5224 dual-right-to-left-b &
  dual_b_pid=$!
  wait "$dual_a_pid"
  wait "$dual_b_pid"
fi

for file in "$evidence_dir"/*.json; do
  case "$file" in
    *default-routes*) continue ;;
  esac
  jq -e '.error == null' "$file" >/dev/null
done

jq -n -e \
  --argjson single_minimum "$(awk -v value="$minimum_single_rail_gbps" 'BEGIN { print value * 1000000000 }')" \
  --slurpfile rail_a_lr "$evidence_dir/rail-a-left-to-right.json" \
  --slurpfile rail_a_rl "$evidence_dir/rail-a-right-to-left.json" \
  '($rail_a_lr[0].end.sum_received.bits_per_second >= $single_minimum) and
   ($rail_a_rl[0].end.sum_received.bits_per_second >= $single_minimum)' \
  </dev/null >/dev/null
if [[ "$interface_count" == 2 ]]; then
  jq -n -e \
    --argjson single_minimum "$(awk -v value="$minimum_single_rail_gbps" 'BEGIN { print value * 1000000000 }')" \
    --argjson dual_minimum "$(awk -v value="$minimum_dual_aggregate_gbps" 'BEGIN { print value * 1000000000 }')" \
    --slurpfile rail_b_lr "$evidence_dir/rail-b-left-to-right.json" \
    --slurpfile rail_b_rl "$evidence_dir/rail-b-right-to-left.json" \
    --slurpfile dual_lr_a "$evidence_dir/dual-left-to-right-a.json" \
    --slurpfile dual_lr_b "$evidence_dir/dual-left-to-right-b.json" \
    --slurpfile dual_rl_a "$evidence_dir/dual-right-to-left-a.json" \
    --slurpfile dual_rl_b "$evidence_dir/dual-right-to-left-b.json" \
    '($rail_b_lr[0].end.sum_received.bits_per_second >= $single_minimum) and
     ($rail_b_rl[0].end.sum_received.bits_per_second >= $single_minimum) and
     (($dual_lr_a[0].end.sum_received.bits_per_second + $dual_lr_b[0].end.sum_received.bits_per_second) >= $dual_minimum) and
     (($dual_rl_a[0].end.sum_received.bits_per_second + $dual_rl_b[0].end.sum_received.bits_per_second) >= $dual_minimum)' \
    </dev/null >/dev/null
fi

cleanup
trap - EXIT INT TERM

for host in "$left_host" "$right_host"; do
  connection_inventory "$host" >"$evidence_dir/$host-connections-after.txt"
  active_connection_inventory "$host" >"$evidence_dir/$host-active-after.txt"
  default_routes "$host" >"$evidence_dir/$host-default-routes-after.json"
  error_counters "$host" >"$evidence_dir/$host-counters-after.txt"
  firewall_inventory "$host" >"$evidence_dir/$host-firewall-after.txt"
  fabric_runtime_inventory "$host" >"$evidence_dir/$host-runtime-after.txt"

  diff -u \
    "$evidence_dir/$host-connections-before.txt" \
    "$evidence_dir/$host-connections-after.txt"
  diff -u \
    "$evidence_dir/$host-active-before.txt" \
    "$evidence_dir/$host-active-after.txt"
  diff -u \
    "$evidence_dir/$host-default-routes-before.json" \
    "$evidence_dir/$host-default-routes-after.json"
  diff -u \
    "$evidence_dir/$host-firewall-before.txt" \
    "$evidence_dir/$host-firewall-after.txt"
  diff -u \
    "$evidence_dir/$host-runtime-before.txt" \
    "$evidence_dir/$host-runtime-after.txt"
  compare_counters \
    "$evidence_dir/$host-counters-before.txt" \
    "$evidence_dir/$host-counters-after.txt"

  verify_postflight_addresses "$host"
done

if [[ "$interface_count" == 1 ]]; then
  physical_summary="one-direct-QSFP56-cable-one-logical-interface-200G-RS-FEC"
  rail_b_left_to_right=null
  rail_b_right_to_left=null
  dual_left_to_right_a=null
  dual_left_to_right_b=null
  dual_right_to_left_a=null
  dual_right_to_left_b=null
else
  physical_summary="one-direct-QSFP56-cable-two-logical-interfaces-200G-RS-FEC"
  rail_b_left_to_right="$(jq '.end.sum_received.bits_per_second' "$evidence_dir/rail-b-left-to-right.json")"
  rail_b_right_to_left="$(jq '.end.sum_received.bits_per_second' "$evidence_dir/rail-b-right-to-left.json")"
  dual_left_to_right_a="$(jq '.end.sum_received.bits_per_second' "$evidence_dir/dual-left-to-right-a.json")"
  dual_left_to_right_b="$(jq '.end.sum_received.bits_per_second' "$evidence_dir/dual-left-to-right-b.json")"
  dual_right_to_left_a="$(jq '.end.sum_received.bits_per_second' "$evidence_dir/dual-right-to-left-a.json")"
  dual_right_to_left_b="$(jq '.end.sum_received.bits_per_second' "$evidence_dir/dual-right-to-left-b.json")"
fi

jq -n \
  --arg physical "$physical_summary" \
  --arg mtu "${target_mtu}-with-${df_payload_bytes}-byte-DF-ping-bidirectional" \
  --argjson rail_a_left_to_right "$(jq '.end.sum_received.bits_per_second' "$evidence_dir/rail-a-left-to-right.json")" \
  --argjson rail_a_right_to_left "$(jq '.end.sum_received.bits_per_second' "$evidence_dir/rail-a-right-to-left.json")" \
  --argjson rail_b_left_to_right "$rail_b_left_to_right" \
  --argjson rail_b_right_to_left "$rail_b_right_to_left" \
  --argjson dual_left_to_right_a "$dual_left_to_right_a" \
  --argjson dual_left_to_right_b "$dual_left_to_right_b" \
  --argjson dual_right_to_left_a "$dual_right_to_left_a" \
  --argjson dual_right_to_left_b "$dual_right_to_left_b" \
  --argjson rdma "$(if [[ -f "$evidence_dir/rdma-summary.json" ]]; then cat "$evidence_dir/rdma-summary.json"; else printf 'null'; fi)" \
  --argjson collective "$(if [[ -f "$evidence_dir/collective/summary.json" ]]; then cat "$evidence_dir/collective/summary.json"; else printf 'null'; fi)" \
  --argjson payload "$(if [[ -f "$evidence_dir/payload/summary.json" ]]; then cat "$evidence_dir/payload/summary.json"; else printf 'null'; fi)" \
  '{
    result: "pass",
    physical: $physical,
    mtu: $mtu,
    tcp_bits_per_second: {
      rail_a_left_to_right: $rail_a_left_to_right,
      rail_a_right_to_left: $rail_a_right_to_left,
      rail_b_left_to_right: $rail_b_left_to_right,
      rail_b_right_to_left: $rail_b_right_to_left,
      dual_left_to_right: [$dual_left_to_right_a, $dual_left_to_right_b],
      dual_right_to_left: [$dual_right_to_left_a, $dual_right_to_left_b]
    },
    rdma: $rdma,
    collective: $collective,
    payload: $payload,
    cleanup: "saved-and-active-connections-default-routes-firewall-runtime-and-error-counters-restored"
  }' | tee "$evidence_dir/summary.json"

printf 'deuces_link_smoke=pass\n'
printf 'private_evidence=%s\n' "$evidence_dir"
