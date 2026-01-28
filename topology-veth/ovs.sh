#!/bin/bash

################################################################################
# SCOPE
#   Initialize a container running Open vSwitch (OVS), creating the main
#   bridge, connecting it to the Ryu controller, and installing base flows
#   necessary for SDN topology operation.
#
# OPERATION
#   - Reads environment variables provided by topology.sh:
#       CONTROLLER_IP   -> Ryu controller address
#       CONTROLLER_PORT -> OpenFlow port (default 6653)
#       BR_NAME         -> Name of the bridge to create (e.g., br1, br2...)
#       VIP, ROUTER_LINK (optional) -> For traffic forwarding to the router
#   - Starts OVS daemons:
#       - Creates conf.db if it doesn't exist
#       - Launches ovsdb-server and ovs-vswitchd
#   - Creates and configures the bridge:
#       - Enables OpenFlow13
#       - Sets fail-mode=secure
#   - Connects the bridge to the Ryu controller (TCP: CONTROLLER_IP:CONTROLLER_PORT).
#   - Waits for controller connection (max 30 attempts).
#   - Installs base flows:
#       1. LLDP -> Sent to controller (for discovery/topology).
#       2. ARP -> Flood (for L2 bootstrap).
#       3. If VIP and ROUTER_LINK are configured:
#            - ARP and IP towards VIP forwarded to the router port.
#       4. Table-miss -> To controller.
#   - Shows ports, flows, and bridge state.
#   - Remains in foreground (tail -f /dev/null) keeping the container alive.
#
# ROLE
#   Each OVS container represents a switch in the topology:
#     - Manages L2 forwarding between hosts and other switches
#     - Connects to the Ryu controller for centralized network logic
#     - Forwards routing traffic to containerized routers, if present
#
# RESULT
#   An OVS switch ready, connected to the controller, with bridge and base flows
#   installed, integrated into the SDN topology created by topology.sh.
################################################################################


# ====================================================
# Initialization script for the OVS container
# ====================================================
# Environment variables passed by topology.sh are:
#   CONTROLLER_IP   (e.g., 10.0.0.250)
#   CONTROLLER_PORT (e.g., 6653 or 6633)
#   BR_NAME         (e.g., br1, br2, etc.)
: "${CONTROLLER_IP:=192.168.1.128}"
: "${CONTROLLER_PORT:=6653}"
: "${BR_NAME:=ovsbr}"
: "${VIP:=}"
: "${ROUTER_LINK:=}" 

echo "[DEBUG] CONTROLLER_IP=${CONTROLLER_IP}"
echo "[DEBUG] CONTROLLER_PORT=${CONTROLLER_PORT}"
echo "[DEBUG] BR_NAME=${BR_NAME}"

# ================================================================================
# 1) Prepare OVS directory and database, and Start ovsdb-server and ovs-vswitchd
# ================================================================================
prepare_ovs_db() {
  echo "[INFO] Creating /etc/openvswitch and /var/run/openvswitch..."
  mkdir -p /etc/openvswitch /var/run/openvswitch

  if [ ! -f /etc/openvswitch/conf.db ]; then
    echo "[INFO] /etc/openvswitch/conf.db does not exist: creating via ovsdb-tool"
    ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
    echo "[OK] created /etc/openvswitch/conf.db"
  else
    echo "[INFO] /etc/openvswitch/conf.db already exists"
  fi
}

start_ovs() {
  echo "[INFO] Starting ovsdb-server and ovs-vswitchd..."

  # 2.1) Launch ovsdb-server
  ovsdb-server /etc/openvswitch/conf.db \
    --remote=punix:/var/run/openvswitch/db.sock \
    --detach

  # 2.2) Initialize configuration
  ovs-vsctl --no-wait init
  # 2.3) Launch ovs-vswitchd and wait for socket creation
  ovs-vswitchd --pidfile --detach
  sleep 1

  if [ ! -S /var/run/openvswitch/db.sock ]; then
    echo "[ERROR] /var/run/openvswitch/db.sock does NOT exist: OVS did not start!"
    exit 1
  fi
  echo "[OK] OVS daemons started, socket /var/run/openvswitch/db.sock present"
}

# =================================================
# 2) Bridge creation and adding ports
# =================================================
setup_data_bridge() {
  echo "[INFO] Creating (if not exists) bridge ${BR_NAME}..."
  ovs-vsctl --may-exist add-br "${BR_NAME}"
  ip link set dev "${BR_NAME}" up
 
  ovs-vsctl set bridge "${BR_NAME}" protocols=OpenFlow13
  ovs-vsctl set-fail-mode "${BR_NAME}" secure
  echo "[OK] Bridge ${BR_NAME} configured."
}

# =============================================
# 3) CONTROLLER Flows
# =============================================
wait_ofport() {
  local ifname="$1" ofp
  for _ in {1..40}; do
    ofp=$(ovs-vsctl --if-exists get Interface "$ifname" ofport 2>/dev/null | tr -d '" ')
    [[ "$ofp" =~ ^[0-9]+$ ]] && [[ "$ofp" -gt 0 ]] && { echo "$ofp"; return 0; }
    sleep 0.2
  done
  echo "[ERR] ofport not ready for $ifname" >&2; return 1
}

setup_flows() {
  # 0) total wipe
  ovs-ofctl -O OpenFlow13 del-flows "$BR_NAME"

  # 1) LLDP -> CONTROLLER (facilitates rest_topology if loaded)
  ovs-ofctl -O OpenFlow13 add-flow "$BR_NAME" \
    "priority=65535,dl_type=0x88cc,dl_dst=01:80:c2:00:00:0e,actions=CONTROLLER:65535"

  # 2) ARP -> FLOOD (more robust for bootstrap)
  ovs-ofctl -O OpenFlow13 add-flow "$BR_NAME" "priority=200,arp,actions=FLOOD"

  # 3) (optional) VRRP/VIP direct to router-link
  if [[ -n "${VIP}" && -n "${ROUTER_LINK}" ]]; then
    if ofp=$(wait_ofport "$ROUTER_LINK"); then
      ovs-ofctl -O OpenFlow13 add-flow "$BR_NAME" \
        "priority=300,arp,arp_tpa=${VIP},actions=output:${ofp}"
      ovs-ofctl -O OpenFlow13 add-flow "$BR_NAME" \
        "priority=300,ip,nw_dst=${VIP},actions=output:${ofp}"
    fi
  fi

  # 4) Table-miss -> CONTROLLER
  ovs-ofctl -O OpenFlow13 add-flow "$BR_NAME" "priority=0,actions=CONTROLLER:65535"
}


# ===============================================================
# 4) Set OpenFlow controller and wait for connection
# ===============================================================
connect_controller() {
  echo "[INFO] Setting OpenFlow controller on ${BR_NAME} => tcp:${CONTROLLER_IP}:${CONTROLLER_PORT}"
  ovs-vsctl set-controller "${BR_NAME}" tcp:"${CONTROLLER_IP}:${CONTROLLER_PORT}"
  # ovs-vsctl set-manager ptcp:6640
  sleep 3
}

wait_for_controller() {
  echo "[INFO] Verifying connectivity with OpenFlow controller..."
  for i in $(seq 1 30); do
    if ovs-vsctl --columns=is_connected list Controller | grep -q true; then
      echo "[OK] OpenFlow controller connected on ${BR_NAME}."
      return 0
    fi
    echo "[WAIT] Waiting for controller connection... ($i/30)"
    sleep 1
  done

  echo "[ERROR] Timeout OpenFlow controller connection on ${BR_NAME}."
  exit 1
}


# =============================================
# Main
# =============================================
main() {
  # Debug: show interfaces and routing immediately
  echo "[DEBUG] First, checking interfaces and routing in OVS container:"
  echo "  -> Interfaces (IPv4 only):"
  ip -o -4 addr show
  echo "  -> Routing:"
  ip route show
  echo "----------------------------------"

  # 1) Create DB and directory and Start OVS daemons
  prepare_ovs_db
  start_ovs

  # 2) Create bridge and add ports
  setup_data_bridge

  # 3) Set controller and wait
  connect_controller
  wait_for_controller

  # 4) Flows
  setup_flows

  echo "[INFO] Ports on $BR_NAME:"
  ovs-vsctl list-ports "$BR_NAME" || true
  echo "[INFO] Flows on $BR_NAME:"
  ovs-ofctl -O OpenFlow13 dump-flows "$BR_NAME" || true
  echo "[INFO] Controller:"; ovs-vsctl get-controller "$BR_NAME" || true
  ovs-vsctl show
  echo "[INFO] OVS container (${BR_NAME}) ready. Staying in foreground..."
  tail -f /dev/null
}

main
