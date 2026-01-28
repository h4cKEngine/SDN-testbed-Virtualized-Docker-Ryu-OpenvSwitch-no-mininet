#!/bin/bash

################################################################################
# SCOPE
#   Initialize the Open vSwitch environment inside the router container,
#   create an OVS bridge connected to a VXLAN port and local interfaces,
#   install minimal OpenFlow rules, and connect to the Ryu controller.
#
# OPERATION
#   - Receives parameters via environment variables (ROUTER, UNDERLAY_IP,
#     VTEP_IPS, REMOTE_*_IP, interfaces, etc.).
#   - Disables IP forwarding in the kernel (routing is delegated to Ryu).
#   - Starts OVS daemons (ovsdb-server, ovs-vswitchd).
#   - Waits for the data interface (e.g., dp0) to be available.
#   - Creates the OVS bridge (default: vxlan-br) and adds:
#       - VXLAN Port (vxlan0) with overlay address and remote peer.
#       - LAN Interface (routerX-link) and data interface (dp0).
#   - Waits for ports to have valid ofports.
#   - Configures the remote Ryu controller (tcp:10.0.100.128:6653),
#     OpenFlow13 protocol, fail-mode=secure.
#   - Installs minimal OpenFlow rules:
#       1. ARP destined for the router VIP -> sent to controller.
#       2. IP destined for the router VIP -> sent to controller.
#       3. Generic ARP -> FLOOD.
#       4. Table-miss -> controller.
#   - Keeps the container alive in background.
#
# ROLE
#   Each containerized router uses this script to:
#     - Manage VXLAN tunnel termination
#     - Connect the local LAN to the overlay domain
#     - Delegate ARP/IP management towards the gateway to the SDN controller
#
# RESULT
#   The router container becomes a configured OVS node,
#   ready to forward traffic via VXLAN and controlled by Ryu.
################################################################################


set -euxo pipefail

: "${ROUTER:?}"
: "${UNDERLAY_IP:?}"
: "${VTEP_IPS:?}"
: "${REMOTE_UNDERLAY_IP:?}"
: "${REMOTE_TRANSIT_IP:?}"
: "${DATA_IFACE:?}"
: "${CONTROL_IFACE:?}"
if [ -z "${ROUTER_LAN_IF:-}" ]; then
  if [ "$ROUTER" = "router1" ]; then
    ROUTER_LAN_IF="router1-link"
  else
    ROUTER_LAN_IF="router2-link"
  fi
fi
: "${VXLAN_ID:=100}"
: "${VXLAN_PORT:=4789}"
: "${OVS_BR:=vxlan-br}"

CONTROLLER_IP=10.0.100.128
CONTROLLER_PORT=6653

disable_ip_forwarding() {
  echo "[Disable IP forwarding]"
  sysctl -w net.ipv4.ip_forward=0
  sysctl -p
}

start_ovs_daemons() {
  echo '[Start OVS daemons]'
  mkdir -p /var/run/openvswitch /etc/openvswitch

  # CREATE DB ONLY if it does not exist
  if [ ! -f /etc/openvswitch/conf.db ]; then
    ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
  fi

  ovsdb-server \
    --remote=punix:/var/run/openvswitch/db.sock \
    --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
    --pidfile --detach

  ovs-vsctl --no-wait init
  ovs-vswitchd --pidfile --detach
}


wait_for_eth0() {
  echo "[Wait for "$DATA_IFACE"]"
  until ip link show "$DATA_IFACE" &>/dev/null; do sleep 1; done
}

setup_ovs_bridge() {
  set -Eeuo pipefail
  local BR="$OVS_BR"
  local VXPORT="vxlan0"

  # 1) Bridge up
  ovs-vsctl --may-exist add-br "$BR"
  ip link set "$BR" up || true
  ovs-vsctl --no-wait init

  # 2) Porta VXLAN
  ovs-vsctl -- \
    --if-exists del-port "$BR" "$VXPORT" -- \
    add-port "$BR" "$VXPORT" -- \
    set Interface "$VXPORT" type=vxlan \
      options:local_ip="$VTEP_IPS" \
      options:remote_ip="$REMOTE_TRANSIT_IP" \
      options:key="$VXLAN_ID" \
      options:dst_port="$VXLAN_PORT"

  # 3) Explicitly add router L2 ports to the bridge
  for IFACE in "$ROUTER_LAN_IF" "$DATA_IFACE"; do
    if ip link show "$IFACE" &>/dev/null; then
      ip link set "$IFACE" up || true
      ovs-vsctl --may-exist add-port "$OVS_BR" "$IFACE"
    fi
  done

  # 4) Wait for ofport ready (vxlan0)
  local VX_OFPORT
  VX_OFPORT="$(ovs-vsctl get Interface "$VXPORT" ofport | tr -d '" ')"
  for i in {1..40}; do
    [[ "$VX_OFPORT" =~ ^[0-9]+$ ]] && [[ "$VX_OFPORT" -gt 0 ]] && break
    sleep 0.2
    VX_OFPORT="$(ovs-vsctl get Interface "$VXPORT" ofport | tr -d '" ')"
  done
  echo "[OK] $VXPORT ofport=$VX_OFPORT"

  echo "[OVS] Bridge $BR ready; vxlan=$VXPORT"
}

insert_openflow_rules() {
  echo "[Insert OpenFlow rules on $OVS_BR]"

  # Clean everything
  ovs-ofctl -O OpenFlow13 del-flows "$OVS_BR"

  # (optional) resolve ofports, useful for logs but NOT needed for flows below
  VXLAN_IF="vxlan0"
  VXLAN_OFPORT=$(ovs-vsctl --bare --columns=ofport find interface name="$VXLAN_IF" | head -n1 || true)
  LAN_OFPORT=$(ovs-vsctl --bare --columns=ofport find interface name="$ROUTER_LAN_IF" | head -n1 || true)
  echo "→ $VXLAN_IF is ofport ${VXLAN_OFPORT:-?}"
  echo "→ $ROUTER_LAN_IF is ofport ${LAN_OFPORT:-?}"

  # Local VIP data (only for match in points 1-2)
  if [[ "$ROUTER" == "router1" ]]; then
    LOCAL_DATA="10.0.1.254"
  else
    LOCAL_DATA="10.0.2.254"
  fi

  # 1) ARP towards router VIP => to controller (rest_router replies)
  ovs-ofctl -O OpenFlow13 add-flow "$OVS_BR" \
    "priority=550,arp,arp_tpa=$LOCAL_DATA,actions=CONTROLLER:65535"

  # 2) IP towards router VIP (e.g. ping gateway) => to controller
  ovs-ofctl -O OpenFlow13 add-flow "$OVS_BR" \
    "priority=1037,ip,nw_dst=$LOCAL_DATA,actions=CONTROLLER:65535"

  # 3) Generic ARP -> FLOOD (normal L2)
  ovs-ofctl -O OpenFlow13 add-flow "$OVS_BR" \
    "priority=150,arp,actions=FLOOD"

    # Table-miss on routers -> CONTROLLER
  ovs-ofctl -O OpenFlow13 add-flow "$OVS_BR" "priority=0,actions=CONTROLLER"


  echo "[OK] flows installed (minimal, router defers to Ryu)"
}


# add/update this function (use "get" instead of "find")
wait_for_ofport() {
  local ifname="$1"
  local ofp
  for i in {1..80}; do
    ofp="$(ovs-vsctl --if-exists get Interface "$ifname" ofport 2>/dev/null | tr -d '[:space:]')"
    if [[ "$ofp" =~ ^[0-9]+$ ]] && [[ "$ofp" -gt 0 ]]; then
      echo "$ofp"; return 0
    fi
    sleep 0.25
  done
  echo "[ERR] ofport not ready for $ifname" >&2
  exit 1
}

# new function: wait for L2 port to exist and be inside bridge
wait_for_lan_port_ready() {
  # 1) link present in router netns
  until ip link show "$ROUTER_LAN_IF" &>/dev/null; do sleep 0.25; done
  # 2) port added to OVS bridge
  until ovs-vsctl list-ports "$OVS_BR" | grep -qx "$ROUTER_LAN_IF"; do sleep 0.25; done
  # 3) valid ofport (>0)
  wait_for_ofport "$ROUTER_LAN_IF" >/dev/null
}



main() {
  disable_ip_forwarding
  start_ovs_daemons

  wait_for_eth0
  setup_ovs_bridge

  wait_for_lan_port_ready

  ovs-vsctl set-controller "$OVS_BR" tcp:${CONTROLLER_IP}:${CONTROLLER_PORT}
  ovs-vsctl set bridge "$OVS_BR" protocols=OpenFlow13
  ovs-vsctl set-fail-mode "$OVS_BR" secure
  ovs-vsctl del-manager

  insert_openflow_rules

  ip a
  ovs-vsctl show

  echo "[Keep container alive]"
  tail -f /dev/null
}

main
