#!/bin/bash

################################################################################
# SCOPO
#   Automatizzare il deploy di un router containerizzato basato su Open vSwitch
#   con supporto a tunnel VXLAN per collegare due domini LAN distinti.
#   Lo script gestisce sia la rete di controllo (control-net) che la rete overlay
#   VXLAN (data-net), collegando il router al relativo switch di frontiera.
#
# FUNZIONAMENTO
#   1. Verifica/effettua il join a Docker Swarm (control-plane).
#   2. Crea la rete Docker "data-net" basata su driver ipvlan (overlay L2).
#   3. Builda l’immagine Docker "router-ovs".
#   4. Avvia un container router (router1 o router2) con:
#        • IP underlay (indirizzo reale)
#        • IP overlay (rete 10.30.30.0/24)
#        • Variabili per peer remoto e interfacce
#   5. Collega il router anche alla rete "control-net" per interagire con Ryu.
#   6. Crea un’interfaccia veth (dp0) host ↔ container e la collega al bridge
#      OVS interno ("vxlan-br").
#   7. Crea una seconda veth per collegare il router al relativo switch OVS:
#        • router1 ↔ ovs1/br1
#        • router2 ↔ ovs5/br5
#   8. Verifica la presenza delle interfacce e dei bridge, e porta tutto up.
#
# PARAMETRI
#   $1 → Nome del router da avviare (router1 o router2)
#
# RETI E INDIRIZZI
#   • CONTROL_NET  (10.0.100.0/24) → gestione e connessione al controller Ryu
#   • DATA_NET     (10.30.30.0/24) → overlay VXLAN tra router1 e router2
#   • UNDERLAY_IP  (rete fisica 192.168.1.0/24) → trasporto del tunnel VXLAN
#   • Ogni router ha:
#       - IP underlay proprio
#       - IP overlay proprio
#       - configurazione del peer remoto
# VXLAN L3->L2
# L2 -> L3 -> L2
# Frame -> UPD/IP -> Frame
# In una rete VXLAN, i passaggi della comunicazione sono i seguenti:
  # 1) Frame Ethernet (L2): Il frame Ethernet originale viene generato dal dispositivo di origine.
  # 2) Incapsulamento in UDP/IP (L3): Il frame Ethernet viene incapsulato in un pacchetto UDP,
    # che a sua volta viene incapsulato in un pacchetto IP per il trasporto attraverso la rete di trasporto (underlay).
  # 3) Decapsulamento in Frame Ethernet (L2): Quando il pacchetto IP raggiunge il nodo di destinazione,
    # viene decapsulato per estrarre il frame Ethernet originale, che viene quindi inoltrato alla destinazione finale.
# Questo processo permette di estendere le reti locali (LAN) su reti di trasporto (underlay) utilizzando l'incapsulamento,
# creando così reti virtuali che possono attraversare reti fisiche diverse.
#
# RISULTATO
#   Viene avviato un router containerizzato che:
#     - ha un bridge OVS interno "vxlan-br"
#     - dispone di un’interfaccia dp0 collegata al piano dati
#     - è connesso al relativo switch di frontiera tramite veth
#     - stabilisce il tunnel VXLAN verso il router remoto
#     - è gestito dal controller Ryu tramite la control-net
#
# USO
#   sudo ./router_vxlan.sh router1
#   sudo ./router_vxlan.sh router2
################################################################################


set -e

ROUTER=$1
CONTROLLER_SWARM_JOIN_TOKEN="SWMTKN-1-2ixpruyyi3ogvb9zk8au20751ioy2c215qneilp0wx6psi704q-6jn09hsd4sqkfhv12l1ibbm1j"
REAL_IFACE="enp3s0"
REAL_GATEWAY="192.168.1.1"
CONTROLLER_IP="192.168.1.128"
CONTROLLER_PORT="6653"
CONTROL_NET="control-net"
CONTROL_IFACE="eth1"
DATA_NET="data-net"
DATA_IFACE="dp0"

declare -A CONTROL_IPS=(
  ["router1"]="10.0.100.21"
  ["router2"]="10.0.100.22"
)

declare -A VTEP_IPS=(
  ["router1"]="10.30.30.11"
  ["router2"]="10.30.30.12"
)
declare -A UNDERLAY_IPS=(
  ["router1"]="192.168.1.250"
  ["router2"]="192.168.1.128" 
)

if [[ "$ROUTER" == "router1" ]]; then
  PEER_ROUTER="router2"
  REAL_IP="192.168.1.250"
  VXLAN_NAME="vxlan-r1"
  ROUTER_LAN_IF="router1-link"
elif [[ "$ROUTER" == "router2" ]]; then
  PEER_ROUTER="router1"
  REAL_IP="192.168.1.128"
  VXLAN_NAME="vxlan-r2"
  ROUTER_LAN_IF="router2-link"
fi

THIS_TRANSIT_IP="${VTEP_IPS[$ROUTER]}"
THIS_UNDERLAY_IP="${UNDERLAY_IPS[$ROUTER]}"
REMOTE_TRANSIT_IP="${VTEP_IPS[$PEER_ROUTER]}"
REMOTE_UNDERLAY_IP="${UNDERLAY_IPS[$PEER_ROUTER]}"

OVS_BRIDGE="vxlan-br"
VXLAN_KEY=100

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

build_image() {
  echo "[BUILD] Building Docker image..."
  docker build -t router-ovs -f ./router/router.Dockerfile ./router/
}

create_networks() {
  # Usa la NIC fisica direttamente come parent
  # ip link set $REAL_IFACE up
  # ip addr flush dev $REAL_IFACE
  # ip addr replace $REAL_IP/24 dev $REAL_IFACE
  # ip route replace default via $REAL_GATEWAY dev $REAL_IFACE

  if ! docker network inspect "$DATA_NET" &>/dev/null; then
    echo "[NET] Creating "$DATA_NET" ipvlan network..."
    docker network create -d ipvlan \
      --subnet=10.30.30.0/24 \
      --gateway=10.30.30.1 \
      -o parent=$REAL_IFACE \
      -o ipvlan_mode=l2 \
      "$DATA_NET"
  fi
}

run_container() {
  echo "[RUN] Launching container $ROUTER..."

  docker run -d --name "$ROUTER" \
    --hostname "$ROUTER" \
    --privileged \
    --network "$DATA_NET" --ip "$THIS_TRANSIT_IP" \
    -e ROUTER="$ROUTER" \
    -e UNDERLAY_IP="$THIS_UNDERLAY_IP" \
    -e VTEP_IPS="$THIS_TRANSIT_IP" \
    -e REMOTE_UNDERLAY_IP="$REMOTE_UNDERLAY_IP" \
    -e REMOTE_TRANSIT_IP="$REMOTE_TRANSIT_IP" \
    -e DATA_IFACE="$DATA_IFACE" \
    -e CONTROL_IFACE="$CONTROL_IFACE" \
    -e ROUTER_LAN_IF=$ROUTER_LAN_IF \
    router-ovs

  sleep 2
  echo "[NET-CONNECT] Connecting "$ROUTER" to $CONTROL_NET..."
  docker network connect "$CONTROL_NET" --ip "${CONTROL_IPS[$ROUTER]}" "$ROUTER"
}

# Crea veth host<->container e collega dp0 a OVS
attach_dp0_to_ovs() {
  set -Eeuo pipefail
  local CNAME="$ROUTER"
  local BR="$OVS_BRIDGE"
  local HOST_END="${CNAME}-dp0"
  local CT_END="dp0"

  docker inspect -f '{{.State.Running}}' "$CNAME" | grep -q true || {
    echo "[ERR] $CNAME non running"; docker logs "$CNAME" || true; exit 1; }

  # Assicura bridge nel container (in caso non chiamassi ensure_vxlan_bridge_in_ct)
  docker exec "$CNAME" ovs-vsctl br-exists "$BR" || docker exec "$CNAME" ovs-vsctl --may-exist add-br "$BR"

  # Assicurati che OVS e il bridge ci siano (idempotente)
  docker exec "$CNAME" sh -c "
    ovs-vsctl --no-wait init
    ovs-vsctl --may-exist add-br $BR
    ovs-vsctl --columns=name find bridge name=$BR >/dev/null
  "

  # Pulizia
  ip link del "$HOST_END" 2>/dev/null || true
  docker exec "$CNAME" ovs-vsctl --if-exists del-port "$BR" "$CT_END" >/dev/null 2>&1 || true
  docker exec "$CNAME" ip link del "$CT_END" >/dev/null 2>&1 || true

  # Crea veth e sposta il peer nel netns del container
  local PID; PID="$(docker inspect -f '{{.State.Pid}}' "$CNAME")"
  ip link add name "$HOST_END" type veth peer name "$CT_END"
  ip link set "$HOST_END" up
  ip link set "$CT_END" netns "$PID"
  docker exec "$CNAME" ip link set "$CT_END" up

  # Aggiungi dp0 al bridge
  docker exec "$CNAME" ovs-vsctl --may-exist add-port "$BR" "$CT_END"

  # (Consigliato per VXLAN)
  # ip link set "$HOST_END" mtu 1450
  # docker exec "$CNAME" ip link set "$CT_END" mtu 1450
  # docker exec "$CNAME" ovs-vsctl set interface vxlan0 mtu_request=1450
  # docker exec "$CNAME" ovs-vsctl set interface dp0    mtu_request=1450

  echo "[DP0] $CT_END aggiunta a $BR (host end: $HOST_END)"
}

connect_veth_to_ovs() {
  set -Eeuo pipefail
  local ROUTER_NAME="$ROUTER"
  local ROUTER_IF="${ROUTER_NAME}-link"
  local SWITCH_IF="${ROUTER_NAME}-link"
  local SWITCH_NAME SWITCH_BRIDGE

  case "$ROUTER_NAME" in
    router1) SWITCH_NAME="ovs1"; SWITCH_BRIDGE="br1" ;;
    router2) SWITCH_NAME="ovs5"; SWITCH_BRIDGE="br5" ;;
    *) echo "[ERR] Router sconosciuto: $ROUTER_NAME"; exit 1 ;;
  esac

  echo "[LINK] Connecting $ROUTER_NAME ↔ $SWITCH_NAME ($SWITCH_BRIDGE)..."

  # PIDs
  local ROUTER_PID; ROUTER_PID=$(docker inspect -f '{{.State.Pid}}' "$ROUTER_NAME")
  local SWITCH_PID; SWITCH_PID=$(docker inspect -f '{{.State.Pid}}' "$SWITCH_NAME")

  # Wait bridges
  for i in {1..40}; do docker exec "$ROUTER_NAME" ovs-vsctl br-exists "$OVS_BRIDGE" && break; sleep 0.3; [[ $i -eq 40 ]] && { echo "[ERR] $OVS_BRIDGE assente su $ROUTER_NAME"; exit 1; }; done
  for i in {1..40}; do docker exec "$SWITCH_NAME" ovs-vsctl br-exists "$SWITCH_BRIDGE" && break; sleep 0.3; [[ $i -eq 40 ]] && { echo "[ERR] $SWITCH_BRIDGE assente su $SWITCH_NAME"; exit 1; }; done

  # Clean
  ip link del "${ROUTER_NAME}-veth" &>/dev/null || true
  ip link del "${SWITCH_NAME}-veth" &>/dev/null || true
  docker exec "$ROUTER_NAME" ip link del "$ROUTER_IF" &>/dev/null || true
  docker exec "$SWITCH_NAME" ip link del "$SWITCH_IF" &>/dev/null || true
  docker exec "$ROUTER_NAME" ovs-vsctl --if-exists del-port "$OVS_BRIDGE" "$ROUTER_IF" &>/dev/null || true
  docker exec "$SWITCH_NAME" ovs-vsctl --if-exists del-port "$SWITCH_BRIDGE" "$SWITCH_IF" &>/dev/null || true

  # Create veth
  ip link add "${ROUTER_NAME}-veth" type veth peer name "${SWITCH_NAME}-veth"

  # Router side
  ip link set "${ROUTER_NAME}-veth" netns "$ROUTER_PID"
  docker exec "$ROUTER_NAME" ip link set "${ROUTER_NAME}-veth" name "$ROUTER_IF"
  docker exec "$ROUTER_NAME" ip link set "$ROUTER_IF" up
  docker exec "$ROUTER_NAME" ip link set "$ROUTER_IF" mtu 1450
  docker exec "$ROUTER_NAME" ovs-vsctl --may-exist add-port "$OVS_BRIDGE" "$ROUTER_IF"

  # Switch side
  ip link set "${SWITCH_NAME}-veth" netns "$SWITCH_PID"
  docker exec "$SWITCH_NAME" ip link set "${SWITCH_NAME}-veth" name "$SWITCH_IF"
  docker exec "$SWITCH_NAME" ip link set "$SWITCH_IF" up
  docker exec "$SWITCH_NAME" ip link set "$SWITCH_IF" mtu 1450
  docker exec "$SWITCH_NAME" ovs-vsctl --may-exist add-port "$SWITCH_BRIDGE" "$SWITCH_IF"

  # Verify
  docker exec "$ROUTER_NAME" ovs-vsctl list-ports "$OVS_BRIDGE" | grep -qx "$ROUTER_IF" || { echo "[ERR] $ROUTER_IF non su $OVS_BRIDGE"; exit 1; }
  docker exec "$SWITCH_NAME" ovs-vsctl list-ports "$SWITCH_BRIDGE" | grep -qx "$SWITCH_IF" || { echo "[ERR] $SWITCH_IF non su $SWITCH_BRIDGE"; exit 1; }

  echo "[OK] Collegato: $ROUTER_NAME($ROUTER_IF) ↔ $SWITCH_NAME($SWITCH_IF)"
}

wait_container_running() {
  local name="$ROUTER"
  for i in {1..40}; do
    if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
      return 0
    fi
    sleep 0.5
  done
  echo "[ERR] $name non è running"; docker logs "$name" || true; exit 1
}


main() {
  ensure_swarm_join
  create_networks

  build_image
  run_container

  wait_container_running
  attach_dp0_to_ovs
  connect_veth_to_ovs

  echo "[DONE] $ROUTER deployed with dual networks (data + control)."
}

main
