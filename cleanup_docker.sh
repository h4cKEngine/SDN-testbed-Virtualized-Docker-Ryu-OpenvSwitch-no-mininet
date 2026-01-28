#!/bin/bash

# ==============================================================================
# TOTAL CLEANUP script for containerized SDN environment
# ==============================================================================
# Scope
#   Aggressively remove ALL test environment components
#   (containers, networks, images, volumes, OVS resources and residual interfaces),
#   bringing the host back to a "clean" state before a new deploy.
#
# ATTENTION (DESTRUCTIVE operations)
#   - Delete containers, custom networks, orphan volumes and (opt.) ALL images.
#   - Executes `docker system prune -a -f` and `docker builder prune -a -f`.
#   - Deletes residual veth/gre at host level and in container netns.
#   - Intervenes on OVS: stops daemons, deletes bridges/interfaces, cleans DB.
#   - Restarts openvswitch-switch and docker services.
#   PROCEED ONLY IF you really intend to reset the entire environment.
#
# Usage
#   sudo ./<script>.sh
#   (no parameters accepted)
#
# Prerequisites
#   - Root privileges.
#   - Docker + Docker Compose, Open vSwitch, iproute2, nsenter, awk/sed/grep.
#   - Basic interface names correctly excluded from filters:
#       lo | enp3s0 | wlo1 | virbr0 | docker0
#     (adapt list to host machine if necessary).
#
# What it does, in order:
#   1) Leaves Swarm (worker): `docker swarm leave --force`.
#   2) Removes Ryu controller and `control-net` control overlay.
#   3) Stops and removes ALL containers (not just h*/ovs*).
#   4) Removes any "bridge" data networks generated for host-switch/switch-switch.
#   5) Executes `docker compose down -v --remove-orphans`, container/volume prune.
#   6) Cleans orphan custom networks (`docker network prune` + targeted delete).
#   7) Advanced system and builder prune.
#   8) (Optional but active) Removes all local Docker images.
#   9) Sets main physical interface to promisc (enp3s0), if needed.
#  10) Deletes residual host-level interfaces (veth/bridge/ovs) except essential ones;
#      tries to remove gre0/gretap0/erspan0 (non-removable templates).
#  11) Removes residual OVS bridges (ovs-system, br-*), kills OVS daemons,
#      cleanup of vxlan-br/br-vxlan/vxlan0 and veth-router*.
#  12) Cleans residual veth interfaces inside containers (via nsenter).
#  13) Performs a "clean" restart of Open vSwitch:
#       - stop daemons, kill processes, delete vxlan*, purge run/log/conf.db.*,
#         start openvswitch-switch service.
#  14) Restarts Docker and prints final state (containers/networks/volumes/Disk usage),
#      plus host IP setup.
#
# Operational Notes
#   - Idempotence: each step is "best effort" (|| true) to tolerate partial states.
#   - Safety: review excluded interface filters before use; do not
#     remove host physical/management links.
#   - Image conservation: to keep local images, comment out
#     `remove_all_images` and/o `advanced_cleanup`.
#   - OVS Environment: the restart block removes residual sockets/locks/logs/DBs that
#     can prevent clean restarts after intensive tests.
#
# Expected Output
#   - No active containers, no residual custom networks, OVS in "fresh" state.
#   - State printed at end of execution: `docker ps -a`, `docker network ls`,
#     `docker volume ls`, `docker system df`, `ip -4 a`.
#
# Responsibility
#   This script is designed for lab environments. Avoid using it on
#   production hosts or with shared Docker resources.
# ==============================================================================


# ====================================================
# Funzioni di cleanup Docker
# ====================================================
stop_and_remove_containers() {
  echo "[1/8] Stopping and removing host and switch containers..."
  #docker ps -a --filter "name=^h[0-9]+" --format "{{.ID}}" | xargs -r docker rm -f
  docker ps -a | xargs -r docker rm -f # Comprende anche altri nomi
}

remove_controller_and_controlnet() {
  echo "[2/8] Removing Ryu container and control network..."
  docker rm -f ryu || true
  docker network rm control-net || true
}

remove_data_networks() {
  echo -e "\n[3/8] Removing datapath topology networks (host-switch and switch-switch)..."
  docker network ls --filter "driver=bridge" --format "{{.Name}}" \
    | grep -E '^(h[0-9]+s[0-9]+-net|s[0-9]+s[0-9]+-net)$' \
    | xargs -r docker network rm || true
}

remove_orphan_resources() {
  echo -e "\n[4/8] Removing orphan containers and volumes..."
  docker compose down -v --remove-orphans || true
  docker container prune -f || true
  docker volume prune -f || true
}

remove_custom_networks() {
  echo -e "\n[5/8] Removing orphan and custom networks (except bridge, host, none)..."
  docker network prune -f
  docker network ls --filter "type=custom" -q | xargs -r docker network rm || true
}

advanced_cleanup() {
  echo -e "\n[6/8] Advanced Docker system prune..."
  docker system prune -a -f || true
  docker builder prune -a -f || true
}

remove_all_images() {
  echo -e "\n[7/8] Removing all Docker images..."
  docker image prune -a -f
  docker images -q | xargs -r docker rmi -f || true
}

delete_veth_and_gre_interfaces() {
  echo -e "\n[8/8] Removing residual interfaces except basic ones..."

  # 1) elimina tutte le interfacce non essenziali (veth, bridge docker, ovs, ecc.)
  ip -o link show \
    | awk -F': ' '{print $2}' \
    | sed 's/@.*//' \
    | grep -Ev '^(lo|enp3s0|wlo1|virbr0|docker0)$' \
    | sort -u \
    | while read -r iface; do
        echo "  Deleting $iface..."
        ip link delete "$iface" 2>/dev/null || true
      done

  # 2) rimuovi le GRE di sistema se ancora presenti
  for gre_if in gre0 gretap0 erspan0; do
    if ip link show "$gre_if" &>/dev/null; then
      echo "  Deleting GRE interface $gre_if..."
      ip link delete "$gre_if" 2>/dev/null || true
    fi
  done

  # 3) ferma ovs-vswitchd e scarica il modulo GRE
  pkill ovs-vswitchd 2>/dev/null || true
  modprobe -r ip_gre 2>/dev/null || true
  
  echo "  [INFO] Interfaces gre0, gretap0, erspan0 are kernel templates and CANNOT be removed manually."
  echo "[OK] Network and GRE interfaces cleaned."
}

# ====================================================
# 9) Rimuove i bridge OVS residui (ovs-system e br-*)
# ====================================================
delete_remaining_ovs_bridges() {
  echo -e "\n[9/9] Removing remaining OVS bridges (ovs-system and br-*)..."
  systemctl restart openvswitch-switch

  # 1) Assicuriamoci che i demoni OVS non stiano ricreando le interfacce
  pkill ovsdb-server ovs-vswitchd 2>/dev/null || true

  # 2) Elimino direttamente ovs-system (se esiste)
  if ip link show ovs-system &>/dev/null; then
    echo "  Deleting ovs-system interface..."
    ip link delete ovs-system 2>/dev/null || true
  fi

  # 3) Trovo e distruggo tutti i bridge che iniziano con 'br-'
  for br in $(ip -o link show \
               | awk -F': ' '{print $2}' \
               | sed 's/@.*//' \
               | grep -E '^br-'); do
    echo "  Deleting bridge $br..."
    # try first with ovs-vsctl (if database is still alive)
    ovs-vsctl --if-exists del-br "$br" 2>/dev/null || true
    # poi, in ogni caso, cancello l'interfaccia a livello Linux
    ip link delete "$br" 2>/dev/null || true
  done
  ovs-vsctl --all destroy Interface
  ovs-vsctl del-br vxlan-br
  ovs-vsctl del-br br-vxlan
  ovs-vsctl del-br vxlan0
  ip link del veth-router1 2>/dev/null || true
  ip link del veth-router2 2>/dev/null || true

  echo "[OK] All residual OVS bridges removed."
}

restart_ovs() {
  sudo systemctl stop openvswitch-switch
  sleep 2
  sudo pkill ovs-vswitchd
  sudo pkill ovsdb-server
  sudo ip link del vxlan-r1 2>/dev/null || true
  sudo ip link del vxlan-r2 2>/dev/null || true
  sudo ip link del vxlan0 2>/dev/null || true
  sudo ip link del vxlan1 2>/dev/null || true
  sudo ip link del vxlan2 2>/dev/null || true

  # WARNING: removes residual sockets and locks!
  rm -rf /var/run/openvswitch/*
  rm -rf /var/log/openvswitch/*
  rm -rf /etc/openvswitch/conf.db.*
  sleep 2
  sudo systemctl start openvswitch-switch
}

cleanup_veth_in_container() {
  echo -e "\n[10/10] Cleaning residual veth interfaces in containers..."

  docker ps -q | while read -r cid; do
    cname=$(docker inspect -f '{{.Name}}' "$cid" | cut -c2-)
    echo "  [INFO] Container: $cname"

    PID=$(docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null)
    if [[ "$PID" =~ ^[0-9]+$ ]] && [[ "$PID" -gt 0 ]]; then
      nsenter -t "$PID" -n ip -o link show \
        | awk -F': ' '{print $2}' \
        | sed 's/@.*//' \
        | grep -Ev '^(lo|eth0|eth1|ovsbr|vxlan0|ovs-system)$' \
        | while read -r iface; do
            echo "    [DEL] Deleting $iface..."
            nsenter -t "$PID" -n ip link delete "$iface" 2>/dev/null || true
        done
    else
      echo "    [WARN] Invalid PID ($PID) for container $cname"
    fi
  done
  echo "[OK] Container interface cleanup completed."
}


# ====================================================
# Main
# ====================================================
main() {
  echo "Leaving docker swarm overlay (as worker)"
  docker swarm leave --force

  remove_controller_and_controlnet
  stop_and_remove_containers
  remove_data_networks
  remove_orphan_resources
  remove_custom_networks
  advanced_cleanup
  remove_all_images
  ip link set enp3s0 promisc on || true
  delete_veth_and_gre_interfaces
  delete_remaining_ovs_bridges
  cleanup_veth_in_container
  restart_ovs
  systemctl restart docker

  echo -e "\nFinal container state:"
  docker ps --all

  echo -e "\nFinal network state:"
  docker network ls

  echo -e "\nFinal volume state:"
  docker volume ls

  echo -e "\nDocker disk usage:"
  docker system df

  ip -4 a
}

main "$@"
