#!/bin/bash

# set_mtu.sh — Align l'MTU overlay su host, router e OVS, con filtro per topologie.
# Usage:
#   sudo ./set_mtu.sh apply
#   sudo NAME_REGEX='^(ovs1|ovs2|h1|h2|router[12])$' ./set_mtu.sh apply   # solo topo-1
# Options: MTU_OVERLAY=1450  BOUNCE=1 (down/up after the set)

set -euo pipefail

: "${MTU_OVERLAY:=1450}"
: "${DOCKER_CMD:=sudo docker}"
: "${NAME_REGEX:=}"          # regex facoltativa per filtrare i container
: "${BOUNCE:=0}"

docker_exec()  { $DOCKER_CMD exec -i "$1" bash -lc "$2" 2>/dev/null || true; }
docker_names() { $DOCKER_CMD ps --format '{{.Names}}'; }
match_regex()  { if [[ -z "$NAME_REGEX" ]]; then cat; else grep -E "$NAME_REGEX" || true; fi; }

discover_ovs()     { docker_names | grep -E '^ovs[0-9]+$'     | match_regex; }
discover_routers() { docker_names | grep -E '^router[0-9]+$'  | match_regex; }
discover_hosts_from_ovs() {
  for O in $(discover_ovs); do
    docker_exec "$O" "ovs-vsctl --data=bare --no-heading --columns=name list Interface"
  done | grep -E '^peer_h[0-9]+(s[0-9]+)?$' | sed -E 's/^peer_//' | sort -u | match_regex
}
discover_hosts_fallback() {
  docker_names | grep -E '^(h[0-9]+|h[0-9]+s[0-9]+)$' | match_regex
}

set_host_mtu() {
  local h="$1" ifname="${2:-eth0}"
  docker_exec "$h" "ip link set dev '$ifname' mtu '$MTU_OVERLAY';
    [[ '$BOUNCE' = '1' ]] && { ip link set dev '$ifname' down; ip link set dev '$ifname' up; }"
}
set_router_mtu() {
  local r="$1"
  docker_exec "$r" "for IF in \$(ip -o link show | awk -F: '{gsub(/ /,\"\"); print \$2}' | egrep '^(eth[0-9]+|vxlan[0-9]+)$'); do
    ip link set dev \"\$IF\" mtu '$MTU_OVERLAY';
    [[ '$BOUNCE' = '1' ]] && { ip link set dev \"\$IF\" down; ip link set dev \"\$IF\" up; }
  done"
}
set_ovs_mtu() {
  local o="$1"
  docker_exec "$o" "for BR in \$(ovs-vsctl list-br); do
    for IF in \$(ovs-vsctl list-ports \"\$BR\"); do
      ovs-vsctl set interface \"\$IF\" mtu_request='$MTU_OVERLAY'
    done
  done"
}

apply_mtu_everywhere() {
  local OVS HOSTS ROUTERS
  OVS="$(discover_ovs)"; HOSTS="$(discover_hosts_from_ovs)"; [[ -z "$HOSTS" ]] && HOSTS="$(discover_hosts_fallback)"
  ROUTERS="$(discover_routers)"

  echo "== Target OVS ==";     printf '%s\n' $OVS
  echo "== Target HOSTS ==";   printf '%s\n' $HOSTS
  echo "== Target ROUTERS =="; printf '%s\n' $ROUTERS

  for o in $OVS;     do [[ -n "$o" ]] && set_ovs_mtu "$o";     done
  for h in $HOSTS;   do [[ -n "$h" ]] && set_host_mtu "$h";     done
  for r in $ROUTERS; do [[ -n "$r" ]] && set_router_mtu "$r";   done
}

verify_mtu() {
  for o in $(discover_ovs); do
    echo "=== OVS $o (name,mtu,mtu_request) ==="
    docker_exec "$o" "ovs-vsctl --format=table --columns=name,mtu,mtu_request list interface"
  done
  echo "=== HOSTS (eth0 ip/mtu) ==="
  local HOSTS="$(discover_hosts_from_ovs)"; [[ -z "$HOSTS" ]] && HOSTS="$(discover_hosts_fallback)"
  for h in $HOSTS; do
    docker_exec "$h" "IP=\$(ip -o -4 addr show eth0 | awk '{print \$4}'); MTU=\$(ip -o link show eth0 | awk '{print \$5}');
echo \"$h: eth0 \$IP mtu \$MTU\""
  done
  echo "=== ROUTERS (eth*/vxlan* mtu) ==="
  for r in $(discover_routers); do
    docker_exec "$r" "ip -o link show | egrep 'eth[0-9]|vxlan[0-9]' | awk '{print \"$r:\", \$2, \$5}'"
  done
}

case "${1:-apply}" in
  apply)  apply_mtu_everywhere; verify_mtu ;;
  verify) verify_mtu ;;
  *) echo "Uso: $0 [apply|verify]"; exit 2 ;;
esac
