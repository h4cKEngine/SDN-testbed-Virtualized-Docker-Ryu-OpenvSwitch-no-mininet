#!/bin/bash

################################################################################
# PURPOSE
#   To initialize the SDN control plane based on Docker Swarm and create
#   the "control-net" overlay network to which the Ryu controller,
#   OVS switches, and routers connect. The script also starts Ryu services
#   using Docker Compose.
#
# OPERATION
#   1. ensure_swarm()
#        - Checks if the node already has Docker Swarm active.
#        - If not active, initializes Swarm on CONTROLLER_IP as manager.
#        - Shows the token to allow other nodes to join as workers.
#   2. ensure_overlay_net()
#        - Checks if the "control-net" overlay network exists.
#        - If it doesn't exist, creates it with overlay driver, subnet 10.0.100.0/24,
#          gateway 10.0.100.1, and --attachable flag (accessible to containers).
#        - Requires the node to be a Swarm manager.
#   3. start_ryu()
#        - Removes any pre-existing Ryu container.
#        - Starts services defined in docker-compose.yml (Ryu controller).
#   4. show_status()
#        - Shows the list of active containers and details of the overlay network.
#   5. show_join_token()
#        - Prints the command useful for worker nodes to join the Swarm.
#
# USAGE
#   sudo ./control-net.sh
#
# RESULT
#   - Docker Swarm initialized and ready (manager on CONTROLLER_IP).
#   - Overlay network "control-net" created and available for switches, routers, and Ryu.
#   - Ryu controller started via Docker Compose and connected to the network.
#   - Status information and join-token printed to screen.
################################################################################


# =========================
# Configuration
# =========================
CONTROLLER_IP="192.168.1.128"
CONTROL_NET="control-net"

ensure_swarm() {
  local state
  state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"

  if [[ "$state" == "active" ]]; then
    echo "[OK] Swarm already initialized (status: $state)."
  else
    echo "> Initializing Docker Swarm on $CONTROLLER_IP..."
    docker swarm init --advertise-addr "$CONTROLLER_IP"
    echo "[OK] Swarm initialized."
  fi

  echo "> Checking status of network '$CONTROL_NET'..."
  docker swarm join-token worker
}

# Create attachable overlay network
ensure_overlay_net() {
  if docker network inspect "$CONTROL_NET" &>/dev/null; then
    echo "[OK] Overlay '$CONTROL_NET' already exists."
    return
  fi

  local is_control
  is_control="$(docker info --format '{{.Swarm.ControlAvailable}}')"
  if [[ "$is_control" != "true" ]]; then
    echo "! Non-manager node: cannot create overlay '$CONTROL_NET'."
    exit 1
  fi

  echo "> Creating overlay network '$CONTROL_NET'..."
  docker network create \
    --driver overlay \
    --subnet 10.0.100.0/24 \
    --gateway 10.0.100.1 \
    --attachable \
    "$CONTROL_NET"
  echo "[OK] Overlay '$CONTROL_NET' created.".
}

start_ryu() {
  docker rm -f ryu || true
  echo "> Starting services with Docker Compose ..."
  docker compose up -d --build
  echo "[OK] Services started."
}


show_status() {
  echo
  echo "> Active containers:"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}'
  echo
  echo "> details of network '$CONTROL_NET':"
  docker network inspect "$CONTROL_NET" | jq
}

show_join_token() {
  echo
  echo "> Command to join a worker node:"
  docker swarm join-token worker
  echo
}

main() {
  ensure_swarm
  ensure_overlay_net
  start_ryu
  show_status
  show_join_token
}

main
