#!/bin/bash

################################################################################
# SCOPO
#   Automatizzare la creazione di una topologia di rete SDN containerizzata
#   composta da host Docker, switch Open vSwitch e un router connesso al
#   controller Ryu. Supporta due scenari topologici predefiniti.
#
# FUNZIONAMENTO (logica principale)
#   1. Verifica che il nodo sia unito a Docker Swarm e, se necessario,
#      esegue il join tramite token.
#   2. Builda le immagini Docker "sdn-host" e "sdn-ovs".
#   3. In base al parametro (1 o 2) seleziona la topologia:
#        • TOPOLOGY 1 → ovs1..ovs4 con host h1..h8 su rete 10.0.1.0/24
#        • TOPOLOGY 2 → ovs5..ovs8 con host h9..h16 su rete 10.0.2.0/24
#   4. Avvia i container OVS, ciascuno con il proprio bridge (brX).
#      - ovs1 e ovs5 hanno anche il ruolo di “gateway virtuale” (VIP .254).
#   5. Collega in catena gli switch tra loro usando coppie veth.
#   6. Avvia i container host, assegnando IP e default gateway.
#   7. Collega ogni host al rispettivo switch tramite veth e configura eth0.
#   8. Verifica la corretta presenza dell’interfaccia eth0 in ciascun host.
#   9. Avvia il router VXLAN corrispondente (router1 per topologia 1,
#      router2 per topologia 2) per abilitare il collegamento L3 con l’altra LAN.
#
# USO
#   sudo ./topology.sh 1   # Crea la prima topologia (LAN 10.0.1.0/24)
#   sudo ./topology.sh 2   # Crea la seconda topologia (LAN 10.0.2.0/24)
#
# RISULTATO
#   Viene creata una topologia SDN dinamica con:
#     - Host Docker come endpoint di rete
#     - Switch OVS interconnessi e gestiti da Ryu (OpenFlow13)
#     - Router con tunnel VXLAN per collegare le due sottoreti
################################################################################


#############################
# Configurazione generale
#############################
CONTROLLER_IP="192.168.1.128"
CONTROLLER_SWARM_JOIN_TOKEN="SWMTKN-1-0uszccblp3b7npyn419x0zr7a23pz28354ljh4sd3ekz7qwcka-buyyqtcpz49rhyiigbmr228jg"
CONTROLLER_PORT="6653"
CONTROLLER_NETWORK="control-net"
NUM_SWITCHES=4
NUM_HOSTS=8

########################################
# 0. Connessione alla rete control-net
########################################
ensure_swarm_join() {
  local state
  state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"

  if [[ "$state" == "active" ]]; then
    echo "✓ Già membro dello Swarm (stato: $state)."
    return
  fi

  echo "➜ Unisco questo nodo allo Swarm del manager $CONTROLLER_IP"
  docker swarm join \
    --token "$CONTROLLER_SWARM_JOIN_TOKEN" \
    "$CONTROLLER_IP":2377
  echo "✓ Nodo unito come worker."
}

##################################
# 1. Build delle immagini
##################################
build_images() {
  HOST_IMAGE="sdn-host:latest"
  OVS_IMAGE="sdn-ovs:latest"

  echo "=== Building Docker images ==="
  docker build -t $HOST_IMAGE -f host.Dockerfile .
  docker build -t $OVS_IMAGE  -f ovs.Dockerfile  .
  echo "=== Build completato ==="
}

#############################################
# 2. Avvia un container OVS/switch
#############################################
create_ovs_container() {
  local ovs_name="$1"
  local bridge_name="$2"

  # Estrai l’ID (es. ovs1 → 1)
  local ovs_id="${ovs_name##ovs}"
  local ctrl_ip="10.0.100.$((100 + ovs_id))"
  local data_ip="10.0.1.$((100 + ovs_id))"

  echo "[INFO] Avvio container OVS: $ovs_name → control-net/$ctrl_ip"

  # Env comuni (access L2: niente controller)
  local envs=(
    -e BR_NAME="$bridge_name"
    -e CONNECT_CONTROLLER=0
  )

  # Env solo per ovs1/ovs5
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
# 3. Avvia un container Host
#############################################
create_host_container() {
  local host_name="$1"
  local host_ip="$2"
  local default_gw="$3"

  echo "[INFO] Avvio container Host: $host_name (IP=$host_ip)..."
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
# 4. Collega un host a un switch (bridge dentro OVS)
###############################################################
connect_host_to_switch() {
  local host_name="$1"
  local ovs_name="$2"
  local bridge_name="$3"
  local ip_addr="$4"
  local default_gw="$5"

  local host_if="${host_name}_eth0"
  local peer_if="peer_${host_name}"

  echo "[INFO] Collegamento: $host_name → $ovs_name:$bridge_name (IP=${ip_addr}, GW=${default_gw})"

  # (1) Elimino eventuali veth residue
  ip link del "$host_if" 2>/dev/null || true
  ip link del "$peer_if" 2>/dev/null || true
  sleep 0.2

  # (2) Creo la veth pair sul nodo fisico (host → OVS)
  ip link add "$host_if" type veth peer name "$peer_if" || {
    echo "[ERROR] impossibile creare veth $host_if ↔ $peer_if"
    return 1
  }

  # (3) Sposto peer_if nel namespace del container OVS
  pid_ovs=$(docker inspect -f '{{.State.Pid}}' "$ovs_name")
  ip link set "$peer_if" netns "$pid_ovs"
  sleep 0.2

  # (4) Dentro il container OVS: porto “peer_if” up e lo attacco al bridge
  docker exec "$ovs_name" ip link set "$peer_if" up
  docker exec "$ovs_name" ovs-vsctl --may-exist add-port "$bridge_name" "$peer_if"

  # (5) Sposto host_if nel namespace del container host e lo configurо
  pid_host=$(docker inspect -f '{{.State.Pid}}' "$host_name")
  ip link set "$host_if" netns "$pid_host"
  sleep 0.2

  # Dentro l’host → rinomino in eth0, metto up e assegno IP
  docker exec "$host_name" ip link set "$host_if" name eth0 up
  docker exec "$host_name" ip addr add "$ip_addr" dev eth0
  docker exec "$host_name" ip route replace default via "$default_gw" dev eth0

  echo "[OK] $host_name collegato a $ovs_name:$bridge_name"
}

########################################################################
# 5. collega gli switch in serie tramite veth a catena in modo dinamico
########################################################################
connect_ovs_chain() {
  local idxs=( "$@" )
  echo "[INFO] Collegamento a catena dinamico tra switch: ${idxs[*]}"
  for (( i=0; i<${#idxs[@]}-1; i++ )); do
    local a=${idxs[i]}
    local b=${idxs[i+1]}
    local ovs_a="ovs${a}"
    local ovs_b="ovs${b}"
    local br_a="br${a}"
    local br_b="br${b}"
    local veth_a="veth_s${a}s${b}"
    local veth_b="veth_s${b}s${a}"

    echo "[INFO]   Collegamento ${br_a} ↔ ${br_b}"
    pid_a=$(docker inspect -f '{{.State.Pid}}' "${ovs_a}")
    pid_b=$(docker inspect -f '{{.State.Pid}}' "${ovs_b}")

    sudo ip link add "${veth_a}" type veth peer name "${veth_b}"

    sudo ip link set "${veth_a}" netns "${pid_a}"
    docker exec "${ovs_a}" ip link set "${veth_a}" name "s${a}-to-s${b}" up
    docker exec "${ovs_a}" ovs-vsctl --may-exist add-port "${br_a}" "s${a}-to-s${b}"

    sudo ip link set "${veth_b}" netns "${pid_b}"
    docker exec "${ovs_b}" ip link set "${veth_b}" name "s${b}-to-s${a}" up
    docker exec "${ovs_b}" ovs-vsctl --may-exist add-port "${br_b}" "s${b}-to-s${a}"

    echo "    ↳ OK ${br_a}↔${br_b}"
  done
  echo "[OK] Switch chaining completato."
}



#########################
# 6. Main
#########################
main() {
  ###############################
  # 0 Controllo esistenza paramentro TOPOLOGY_NO
  ###############################
  if [[ $# -ne 1 || "$1" != 1 && "$1" != 2 ]]; then
    echo "[USAGE] sudo ./topology.sh <TOPOLOGY_NO>"
    echo "        TOPOLOGY_NO = 1 → prima topologia"
    echo "        TOPOLOGY_NO = 2 → seconda topologia"
    exit 1
  fi

  TOPOLOGY_NO="$1"
  ###############################
  # 6.0 Unisci questo nodo allo Swarm
  ###############################
  ensure_swarm_join
  sleep 2
  
  ###############################
  # 6.1 Build delle immagini
  ###############################
  build_images

  ###############################
  # 6.2 Definisci la TOPOLOGY
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
  # 6.3 Raccogli la lista univoca di switch
  ###############################
  declare -A SWITCHES=()
  for entry in "${TOPOLOGY[@]}"; do
    set -- $entry       # $2 = ovsX
    SWITCHES["$2"]=1
  done

  # Estrai e ordina gli indici numerici
  declare -a INDICES=()
  for ovs in "${!SWITCHES[@]}"; do
    INDICES+=( "${ovs#ovs}" )
  done
  IFS=$'\n' INDICES=( $(sort -n <<<"${INDICES[*]}") ); unset IFS

  echo "[DEBUG] INDICES per chaining: ${INDICES[*]}"

  ###############################
  # 6.4 Avvia i container OVS
  ###############################
  for idx in "${INDICES[@]}"; do
    ovs_name="ovs${idx}"
    br_name="br${idx}"
    create_ovs_container "$ovs_name" "$br_name"
  done
  sleep 2

  ###############################
  # 6.5 Chaining dinamico degli switch
  ###############################
  connect_ovs_chain "${INDICES[@]}"
  sleep 1

  ###############################
  # 6.6 Crea i container host
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
  # 6.7 Collega tutti gli host ai rispettivi switch
  ###############################
  for entry in "${TOPOLOGY[@]}"; do
    set -- $entry
    connect_host_to_switch "$1" "$2" "$3" "$4" "$5" &
  done
  wait

  ###############################
  # 6.8 Verifica che eth0 sia presente negli host
  ###############################
  echo "[INFO] Verifica interfacce eth0 sui container host…"
  for host in "${HOSTS[@]}"; do
    for i in {1..50}; do
      if docker exec "$host" ip link show dev eth0 &>/dev/null; then
        echo "  → $host: eth0 OK"
        break
      fi
      sleep 0.2
    done
  done

  echo "[INFO] Topologia creata: ${#HOSTS[@]} host su ${#INDICES[@]} switch collegati a Ryu($CONTROLLER_NETWORK:$CONTROLLER_PORT)."

  # 6.8.1 Sincronizza con Ryu (hostmap + allowed pairs)
  ./register_hosts.sh $TOPOLOGY_NO

  ###############################
  # 6.9 Avvia router e OVS
  ###############################
  echo "[INFO] Avvio il router..."
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
