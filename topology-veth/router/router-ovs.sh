#!/bin/bash

################################################################################
# SCOPO
#   Inizializzare l’ambiente Open vSwitch all’interno del container router,
#   creare un bridge OVS connesso a una porta VXLAN e alle interfacce locali,
#   installare regole OpenFlow minime e collegarsi al controller Ryu.
#
# FUNZIONAMENTO
#   • Riceve parametri tramite variabili d’ambiente (ROUTER, UNDERLAY_IP,
#     VTEP_IPS, REMOTE_*_IP, interfacce, ecc.).
#   • Disabilita l’IP forwarding nel kernel (il routing viene delegato a Ryu).
#   • Avvia i demoni OVS (ovsdb-server, ovs-vswitchd).
#   • Attende la disponibilità dell’interfaccia dati (es. dp0).
#   • Crea il bridge OVS (default: vxlan-br) e aggiunge:
#       – Porta VXLAN (vxlan0) con indirizzo overlay e peer remoto.
#       – Interfaccia LAN (routerX-link) e interfaccia dati (dp0).
#   • Attende che le porte abbiano ofport validi.
#   • Configura il controller remoto Ryu (tcp:10.0.100.128:6653),
#     protocollo OpenFlow13, fail-mode=secure.
#   • Installa regole OpenFlow minime:
#       1. ARP destinati al VIP del router → inviati al controller.
#       2. IP destinati al VIP del router → inviati al controller.
#       3. ARP generici → FLOOD.
#       4. Table-miss → controller.
#   • Mantiene il container vivo in background.
#
# RUOLO
#   Ogni router containerizzato usa questo script per:
#     – gestire la terminazione del tunnel VXLAN
#     – collegare la LAN locale al dominio overlay
#     – demandare al controller SDN la gestione di ARP/IP verso il gateway
#
# RISULTATO
#   Il container router diventa un nodo OVS configurato,
#   pronto a inoltrare traffico tramite VXLAN e controllato da Ryu.
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

  # CREA il DB SOLO se non esiste
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

  # 3) Aggiungi esplicitamente le porte L2 del router al bridge
  for IFACE in "$ROUTER_LAN_IF" "$DATA_IFACE"; do
    if ip link show "$IFACE" &>/dev/null; then
      ip link set "$IFACE" up || true
      ovs-vsctl --may-exist add-port "$OVS_BR" "$IFACE"
    fi
  done

  # 4) Attesa ofport pronto (vxlan0)
  local VX_OFPORT
  VX_OFPORT="$(ovs-vsctl get Interface "$VXPORT" ofport | tr -d '" ')"
  for i in {1..40}; do
    [[ "$VX_OFPORT" =~ ^[0-9]+$ ]] && [[ "$VX_OFPORT" -gt 0 ]] && break
    sleep 0.2
    VX_OFPORT="$(ovs-vsctl get Interface "$VXPORT" ofport | tr -d '" ')"
  done
  echo "[OK] $VXPORT ofport=$VX_OFPORT"

  echo "[OVS] Bridge $BR pronto; vxlan=$VXPORT"
}

insert_openflow_rules() {
  echo "[Insert OpenFlow rules on $OVS_BR]"

  # Pulisci tutto
  ovs-ofctl -O OpenFlow13 del-flows "$OVS_BR"

  # (facoltativo) risolvi gli ofport, utile per log ma NON servono per i flow qui sotto
  VXLAN_IF="vxlan0"
  VXLAN_OFPORT=$(ovs-vsctl --bare --columns=ofport find interface name="$VXLAN_IF" | head -n1 || true)
  LAN_OFPORT=$(ovs-vsctl --bare --columns=ofport find interface name="$ROUTER_LAN_IF" | head -n1 || true)
  echo "→ $VXLAN_IF is ofport ${VXLAN_OFPORT:-?}"
  echo "→ $ROUTER_LAN_IF is ofport ${LAN_OFPORT:-?}"

  # Dati VIP locali (solo per match del punto 1-2)
  if [[ "$ROUTER" == "router1" ]]; then
    LOCAL_DATA="10.0.1.254"
  else
    LOCAL_DATA="10.0.2.254"
  fi

  # 1) ARP verso il VIP del router => al controller (risponde rest_router)
  ovs-ofctl -O OpenFlow13 add-flow "$OVS_BR" \
    "priority=550,arp,arp_tpa=$LOCAL_DATA,actions=CONTROLLER:65535"

  # 2) IP verso il VIP del router (es. ping al gateway) => al controller
  ovs-ofctl -O OpenFlow13 add-flow "$OVS_BR" \
    "priority=1037,ip,nw_dst=$LOCAL_DATA,actions=CONTROLLER:65535"

  # 3) ARP generico -> FLOOD (normale L2)
  ovs-ofctl -O OpenFlow13 add-flow "$OVS_BR" \
    "priority=150,arp,actions=FLOOD"

    # Table-miss sui router -> CONTROLLER
  ovs-ofctl -O OpenFlow13 add-flow "$OVS_BR" "priority=0,actions=CONTROLLER"


  echo "[OK] flows installed (minimal, router defers to Ryu)"
}


# aggiungi/aggiorna questa funzione (usa "get" invece di "find")
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
  echo "[ERR] ofport non pronto per $ifname" >&2
  exit 1
}

# nuova funzione: aspetta che la porta L2 esista e sia dentro al bridge
wait_for_lan_port_ready() {
  # 1) link presente nel netns del router
  until ip link show "$ROUTER_LAN_IF" &>/dev/null; do sleep 0.25; done
  # 2) porta aggiunta al bridge OVS
  until ovs-vsctl list-ports "$OVS_BR" | grep -qx "$ROUTER_LAN_IF"; do sleep 0.25; done
  # 3) ofport valido (>0)
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
