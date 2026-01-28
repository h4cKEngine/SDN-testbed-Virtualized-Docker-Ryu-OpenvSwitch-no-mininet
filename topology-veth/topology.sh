#!/bin/bash

################################################################################
# SCOPE
#   Automate the creation of a containerized SDN network topology
#   composed of Docker hosts, Open vSwitch switches and a router connected to the
#   Ryu controller. Supports two predefined topological scenarios.
#
# OPERATION (main logic)
#   1. Checks that the node is joined to Docker Swarm and, if necessary,
#      performs the join via token.
#   2. Builds the "sdn-host" and "sdn-ovs" Docker images.
#   3. Based on the parameter (1 or 2) selects the topology:
#        * TOPOLOGY 1 -> ovs1..ovs4 with hosts h1..h8 on network 10.0.1.0/24
#        * TOPOLOGY 2 -> ovs5..ovs8 with hosts h9..h16 on network 10.0.2.0/24
#   4. Starts the OVS containers, each with its own bridge (brX).
#      - ovs1 and ovs5 also have the role of "virtual gateway" (VIP .254).
#   5. Connects the switches in a chain using veth pairs.
#   6. Starts the host containers, assigning IPs and default gateways.
#   7. Connects each host to its respective switch via veth and configures eth0.
#   8. Verifies the correct presence of the eth0 interface in each host.
#   9. Starts the corresponding VXLAN router (router1 for topology 1,
#      router2 for topology 2) to enable L3 connection with the other LAN.
#
# USAGE
#   sudo ./topology.sh 1   # Creates the first topology (LAN 10.0.1.0/24)
#   sudo ./topology.sh 2   # Creates the second topology (LAN 10.0.2.0/24)
#
# RESULT
#   A dynamic SDN topology is created with:
#     - Docker Hosts as network endpoints
#     - Interconnected OVS Switches managed by Ryu (OpenFlow13)
#     - Router with VXLAN tunnel to connect the two subnets
################################################################################


#############################
# General configuration
#############################
CONTROLLER_IP="192.168.1.128"
CONTROLLER_SWARM_JOIN_TOKEN="SWMTKN-1-0uszccblp3b7npyn419x0zr7a23pz28354ljh4sd3ekz7qwcka-buyyqtcpz49rhyiigbmr228jg"
CONTROLLER_PORT="6653"
CONTROLLER_NETWORK="control-net"
NUM_SWITCHES=4
NUM_HOSTS=8

########################################
# 0. Connection to control-net
########################################
ensure_swarm_join() {
  local state
  state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"

  if [[ "$state" == "active" ]]; then
    echo "[OK] Already Swarm member (state: $state)."
    return
  fi

  echo "[INFO] Joining this node to Swarm of manager $CONTROLLER_IP"
  docker swarm join \
    --token "$CONTROLLER_SWARM_JOIN_TOKEN" \
    "$CONTROLLER_IP":2377
  echo "[OK] Node joined as worker."
}

##################################
# 1. Build images
##################################
build_images() {
  HOST_IMAGE="sdn-host:latest"
  OVS_IMAGE="sdn-ovs:latest"

  echo "=== Building Docker images ==="
  docker build -t $HOST_IMAGE -f host.Dockerfile .
  docker build -t $OVS_IMAGE  -f ovs.Dockerfile  .
  echo "=== Build completed ==="
}

#############################################
# 2. Start an OVS/switch container
#############################################
create_ovs_container() {
  local ovs_name="$1"
  local bridge_name="$2"

  # Extract ID (e.g. ovs1 -> 1)
  local ovs_id="${ovs_name##ovs}"
  local ctrl_ip="10.0.100.$((100 + ovs_id))"
  local data_ip="10.0.1.$((100 + ovs_id))"

  echo "[INFO] Starting OVS container: $ovs_name -> control-net/$ctrl_ip"

  # Common Envs (L2 access: no controller)
  local envs=(
    -e BR_NAME="$bridge_name"
    -e CONNECT_CONTROLLER=0
  )

  # Env only for ovs1/ovs5
  case "$ovs_name" in
    ovs1)
      envs+=( -e VIP=10.0.1.254 -e ROUTER_LINK=router1-link )
      ;;
    ovs5)
      envs+=( -e VIP=10.0.2.254 -e ROUTER_LINK=router2-link )
      ;;
    *) : ;;
  esac

  docker run -d \
    --name "$ovs_name" \
    --privileged \
    --network "$CONTROLLER_NETWORK" \
    --ip "$ctrl_ip" \
    --restart on-failure \
    "${envs[@]}" \
    "$OVS_IMAGE"

  sleep 2
}

#############################################
# 3. Start a Host container
#############################################
create_host_container() {
  local host_name="$1"
  local host_ip="$2"
  local default_gw="$3"

  echo "[INFO] Starting Host container: $host_name (IP=$host_ip)..."
  docker run -d \
    --name "$host_name" \
    --privileged \
    --network none \
    --restart=always \
    -e HOST_IP="$host_ip" \
    -e DEFAULT_GW="$default_gw" \
    $HOST_IMAGE
}

###############################################################
# 4. Connect a host to a switch (bridge inside OVS)
###############################################################
connect_host_to_switch() {
  local host_name="$1"
  local ovs_name="$2"
  local bridge_name="$3"
  local ip_addr="$4"
  local default_gw="$5"

  local host_if="${host_name}_eth0"
  local peer_if="peer_${host_name}"

  echo "[INFO] Connecting: $host_name -> $ovs_name:$bridge_name (IP=${ip_addr}, GW=${default_gw})"

  # (1) Delete residual veths
  ip link del "$host_if" 2>/dev/null || true
  ip link del "$peer_if" 2>/dev/null || true
  sleep 0.2

  # (2) Create veth pair on physical node (host -> OVS)
  ip link add "$host_if" type veth peer name "$peer_if" || {
    echo "[ERROR] cannot create veth $host_if ↔ $peer_if"
    return 1
  }

  # (3) Move peer_if into OVS container namespace
  pid_ovs=$(docker inspect -f '{{.State.Pid}}' "$ovs_name")
  ip link set "$peer_if" netns "$pid_ovs"
  sleep 0.2

  # (4) Inside OVS container: bring "peer_if" up and attach to bridge
  docker exec "$ovs_name" ip link set "$peer_if" up
  docker exec "$ovs_name" ovs-vsctl --may-exist add-port "$bridge_name" "$peer_if"

  # (5) Move host_if into host container namespace and configure it
  pid_host=$(docker inspect -f '{{.State.Pid}}' "$host_name")
  ip link set "$host_if" netns "$pid_host"
  sleep 0.2

  # Inside host -> rename to eth0, bring up and assign IP
  docker exec "$host_name" ip link set "$host_if" name eth0 up
  docker exec "$host_name" ip addr add "$ip_addr" dev eth0
  docker exec "$host_name" ip route replace default via "$default_gw" dev eth0

  echo "[OK] $host_name connected to $ovs_name:$bridge_name"
}

########################################################################
# 5. Connect switches in series via chained veth dynamically
########################################################################
connect_ovs_chain() {
  local idxs=( "$@" )
  echo "[INFO] Dynamic daisy-chain connection between switches: ${idxs[*]}"
  for (( i=0; i<${#idxs[@]}-1; i++ )); do
    local a=${idxs[i]}
    local b=${idxs[i+1]}
    local ovs_a="ovs${a}"
    local ovs_b="ovs${b}"
    local br_a="br${a}"
    local br_b="br${b}"
    local veth_a="veth_s${a}s${b}"
    local veth_b="veth_s${b}s${a}"

    echo "[INFO]   Connecting ${br_a} <-> ${br_b}"
    pid_a=$(docker inspect -f '{{.State.Pid}}' "${ovs_a}")
    pid_b=$(docker inspect -f '{{.State.Pid}}' "${ovs_b}")

    sudo ip link add "${veth_a}" type veth peer name "${veth_b}"

    sudo ip link set "${veth_a}" netns "${pid_a}"
    docker exec "${ovs_a}" ip link set "${veth_a}" name "s${a}-to-s${b}" up
    docker exec "${ovs_a}" ovs-vsctl --may-exist add-port "${br_a}" "s${a}-to-s${b}"

    sudo ip link set "${veth_b}" netns "${pid_b}"
    docker exec "${ovs_b}" ip link set "${veth_b}" name "s${b}-to-s${a}" up
    docker exec "${ovs_b}" ovs-vsctl --may-exist add-port "${br_b}" "s${b}-to-s${a}"

    echo "    -> OK ${br_a}<->${br_b}"
  done
  echo "[OK] Switch chaining completed."
}



#########################
# 6. Main
#########################
main() {
  ###############################
  # 0 Check TOPOLOGY_NO parameter existence
  ###############################
  if [[ $# -ne 1 || "$1" != 1 && "$1" != 2 ]]; then
    echo "[USAGE] sudo ./topology.sh <TOPOLOGY_NO>"
    echo "        TOPOLOGY_NO = 1 -> first topology"
    echo "        TOPOLOGY_NO = 2 -> second topology"
    exit 1
  fi

  TOPOLOGY_NO="$1"
  ###############################
  # 6.0 Join this node to the Swarm
  ###############################
  ensure_swarm_join
  sleep 2
  
  ###############################
  # 6.1 Build images
  ###############################
  build_images

  ###############################
  # 6.2 Define TOPOLOGY
  ###############################
  if [[ "$TOPOLOGY_NO" == 1 ]]; then
    declare -a TOPOLOGY=(
      "h1 ovs1 br1 10.0.1.1/24 10.0.1.254"
      "h2 ovs1 br1 10.0.1.2/24 10.0.1.254"
      "h3 ovs2 br2 10.0.1.3/24 10.0.1.254"
      "h4 ovs2 br2 10.0.1.4/24 10.0.1.254"
      "h5 ovs3 br3 10.0.1.5/24 10.0.1.254"
      "h6 ovs3 br3 10.0.1.6/24 10.0.1.254"
      "h7 ovs4 br4 10.0.1.7/24 10.0.1.254"
      "h8 ovs4 br4 10.0.1.8/24 10.0.1.254"
    )
  elif [[ "$TOPOLOGY_NO" == 2 ]]; then
    declare -a TOPOLOGY=(
      "h9  ovs5 br5  10.0.2.9/24   10.0.2.254"
      "h10 ovs5 br5  10.0.2.10/24  10.0.2.254"
      "h11 ovs6 br6  10.0.2.11/24  10.0.2.254"
      "h12 ovs6 br6  10.0.2.12/24  10.0.2.254"
      "h13 ovs7 br7  10.0.2.13/24  10.0.2.254"
      "h14 ovs7 br7  10.0.2.14/24  10.0.2.254"
      "h15 ovs8 br8  10.0.2.15/24  10.0.2.254"
      "h16 ovs8 br8  10.0.2.16/24  10.0.2.254"
    )
  fi

  ###############################
  # 6.3 Collect unique list of switches
  ###############################
  declare -A SWITCHES=()
  for entry in "${TOPOLOGY[@]}"; do
    set -- $entry       # $2 = ovsX
    SWITCHES["$2"]=1
  done

  # Extract and sort numeric indices
  declare -a INDICES=()
  for ovs in "${!SWITCHES[@]}"; do
    INDICES+=( "${ovs#ovs}" )
  done
  IFS=$'\n' INDICES=( $(sort -n <<<"${INDICES[*]}") ); unset IFS

  echo "[DEBUG] INDICES for chaining: ${INDICES[*]}"

  ###############################
  # 6.4 Start OVS containers
  ###############################
  for idx in "${INDICES[@]}"; do
    ovs_name="ovs${idx}"
    br_name="br${idx}"
    create_ovs_container "$ovs_name" "$br_name"
  done
  sleep 2

  ###############################
  # 6.5 Dynamic switch chaining
  ###############################
  connect_ovs_chain "${INDICES[@]}"
  sleep 1

  ###############################
  # 6.6 Create host containers
  ###############################
  declare -a HOSTS=()
  for entry in "${TOPOLOGY[@]}"; do
    set -- $entry
    host_name="$1"; host_ip="$4"; gw="$5"; br="$3"
    create_host_container "$host_name" "$host_ip" "$gw" "$br"
    HOSTS+=( "$host_name" )
  done
  sleep 2

  ###############################
  # 6.7 Connect all hosts to their respective switches
  ###############################
  for entry in "${TOPOLOGY[@]}"; do
    set -- $entry
    connect_host_to_switch "$1" "$2" "$3" "$4" "$5" &
  done
  wait

  ###############################
  # 6.8 Verifica che eth0 sia presente negli host
  ###############################
  echo "[INFO] Checking eth0 interfaces on host containers..."
  for host in "${HOSTS[@]}"; do
    for i in {1..50}; do
      if docker exec "$host" ip link show dev eth0 &>/dev/null; then
        echo "  -> $host: eth0 OK"
        break
      fi
      sleep 0.2
    done
  done

  echo "[INFO] Topology created: ${#HOSTS[@]} hosts on ${#INDICES[@]} switches connected to Ryu($CONTROLLER_NETWORK:$CONTROLLER_PORT)."

  # 6.8.1 Sync with Ryu (hostmap + allowed pairs)
  ./register_hosts.sh $TOPOLOGY_NO

  ###############################
  # 6.9 Start router and OVS
  ###############################
  echo "[INFO] Starting router..."
  if [[ "$TOPOLOGY_NO" == 1 ]]; then
    ./router/router_vxlan.sh router1
    echo "[LOGS] router1"
    docker logs router1
  elif [[ "$TOPOLOGY_NO" == 2 ]]; then
    ./router/router_vxlan.sh router2
    echo "[LOGS] router2"
    docker logs router2
  fi

  ./set_mtu.sh apply
  ./set_mtu.sh verify
}

main "$@"
