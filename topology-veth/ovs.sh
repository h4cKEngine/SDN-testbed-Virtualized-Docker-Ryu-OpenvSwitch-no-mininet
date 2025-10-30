#!/bin/bash

################################################################################
# SCOPO
#   Inizializzare un container che esegue Open vSwitch (OVS), creando il bridge
#   principale, collegandolo al controller Ryu e installando i flussi base
#   necessari al funzionamento della topologia SDN.
#
# FUNZIONAMENTO
#   • Legge variabili d’ambiente fornite da topology.sh:
#       CONTROLLER_IP   → indirizzo del controller Ryu
#       CONTROLLER_PORT → porta OpenFlow (default 6653)
#       BR_NAME         → nome del bridge da creare (es. br1, br2…)
#       VIP, ROUTER_LINK (opzionali) → per inoltro traffico verso il router
#   • Avvia i demoni OVS:
#       – Crea conf.db se non esiste
#       – Lancia ovsdb-server e ovs-vswitchd
#   • Crea e configura il bridge:
#       – Attiva OpenFlow13
#       – Imposta fail-mode=secure
#   • Collega il bridge al controller Ryu (TCP: CONTROLLER_IP:CONTROLLER_PORT).
#   • Attende la connessione del controller (max 30 tentativi).
#   • Installa i flussi di base:
#       1. LLDP → inviato al controller (per discovery/topologia).
#       2. ARP → flood (per bootstrap L2).
#       3. Se configurati VIP e ROUTER_LINK:
#            - ARP e IP verso VIP inoltrati alla porta del router.
#       4. Table-miss → al controller.
#   • Mostra porte, flussi e stato del bridge.
#   • Rimane in foreground (tail -f /dev/null) mantenendo vivo il container.
#
# RUOLO
#   Ogni container OVS rappresenta uno switch della topologia:
#     – gestisce il forwarding L2 tra host e altri switch
#     – si collega al controller Ryu per logica di rete centralizzata
#     – inoltra il traffico di routing ai router containerizzati, se presenti
#
# RISULTATO
#   Uno switch OVS pronto, connesso al controller, con bridge e flussi base
#   installati, integrato nella topologia SDN creata da topology.sh.
################################################################################


# ====================================================
# Script di inizializzazione per il container OVS
# ====================================================
# Le variabili d'ambiente passate da topology.sh sono:
#   CONTROLLER_IP   (es. 10.0.0.250)
#   CONTROLLER_PORT (es. 6653 o 6633)
#   BR_NAME         (es. br1, br2, ecc.)
: "${CONTROLLER_IP:=192.168.1.128}"
: "${CONTROLLER_PORT:=6653}"
: "${BR_NAME:=ovsbr}"
: "${VIP:=}"
: "${ROUTER_LINK:=}" 

echo "[DEBUG] CONTROLLER_IP=${CONTROLLER_IP}"
echo "[DEBUG] CONTROLLER_PORT=${CONTROLLER_PORT}"
echo "[DEBUG] BR_NAME=${BR_NAME}"

# ================================================================================
# 1) Preparo la directory e il database OVS e Avvio ovsdb-server e ovs-vswitchd
# ================================================================================
prepare_ovs_db() {
  echo "[INFO] Creo directory /etc/openvswitch e /var/run/openvswitch..."
  mkdir -p /etc/openvswitch /var/run/openvswitch

  if [ ! -f /etc/openvswitch/conf.db ]; then
    echo "[INFO] /etc/openvswitch/conf.db non esiste: lo creo via ovsdb-tool"
    ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
    echo "[OK] creato /etc/openvswitch/conf.db"
  else
    echo "[INFO] /etc/openvswitch/conf.db già esistente"
  fi
}

start_ovs() {
  echo "[INFO] Avvio ovsdb-server e ovs-vswitchd..."

  # 2.1) Lancio ovsdb-server
  ovsdb-server /etc/openvswitch/conf.db \
    --remote=punix:/var/run/openvswitch/db.sock \
    --detach

  # 2.2) Inizializzo la configurazione
  ovs-vsctl --no-wait init
  # 2.3) Lancio ovs-vswitchd e attendo la creazione della socket
  ovs-vswitchd --pidfile --detach
  sleep 1

  if [ ! -S /var/run/openvswitch/db.sock ]; then
    echo "[ERROR] /var/run/openvswitch/db.sock NON esiste: OVS non è partito!"
    exit 1
  fi
  echo "[OK] Demoni OVS avviati, socket /var/run/openvswitch/db.sock presente"
}

# =================================================
# 2) Creazione del bridge e aggiunta delle porte
# =================================================
setup_data_bridge() {
  echo "[INFO] Creo (se non esiste) il bridge ${BR_NAME}..."
  ovs-vsctl --may-exist add-br "${BR_NAME}"
  ip link set dev "${BR_NAME}" up
 
  ovs-vsctl set bridge "${BR_NAME}" protocols=OpenFlow13
  ovs-vsctl set-fail-mode "${BR_NAME}" secure
  echo "[OK] Bridge ${BR_NAME} configurato."
}

# =============================================
# 3) Flussi CONTROLLER
# =============================================
wait_ofport() {
  local ifname="$1" ofp
  for _ in {1..40}; do
    ofp=$(ovs-vsctl --if-exists get Interface "$ifname" ofport 2>/dev/null | tr -d '" ')
    [[ "$ofp" =~ ^[0-9]+$ ]] && [[ "$ofp" -gt 0 ]] && { echo "$ofp"; return 0; }
    sleep 0.2
  done
  echo "[ERR] ofport non pronto per $ifname" >&2; return 1
}

setup_flows() {
  # 0) wipe totale
  ovs-ofctl -O OpenFlow13 del-flows "$BR_NAME"

  # 1) LLDP -> CONTROLLER (facilita rest_topology se lo carichi)
  ovs-ofctl -O OpenFlow13 add-flow "$BR_NAME" \
    "priority=65535,dl_type=0x88cc,dl_dst=01:80:c2:00:00:0e,actions=CONTROLLER:65535"

  # 2) ARP -> FLOOD (più robusto per bootstrap)
  ovs-ofctl -O OpenFlow13 add-flow "$BR_NAME" "priority=200,arp,actions=FLOOD"

  # 3) (opzionale) VRRP/VIP diretto al router-link
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
# 4) Imposto il controller OpenFlow e ne attendo la connessione
# ===============================================================
connect_controller() {
  echo "[INFO] Imposto controller OpenFlow su ${BR_NAME} => tcp:${CONTROLLER_IP}:${CONTROLLER_PORT}"
  ovs-vsctl set-controller "${BR_NAME}" tcp:"${CONTROLLER_IP}:${CONTROLLER_PORT}"
  # ovs-vsctl set-manager ptcp:6640
  sleep 3
}

wait_for_controller() {
  echo "[INFO] Verifico la connettività con il controller OpenFlow..."
  for i in $(seq 1 30); do
    if ovs-vsctl --columns=is_connected list Controller | grep -q true; then
      echo "[OK] OpenFlow controller connesso su ${BR_NAME}."
      return 0
    fi
    echo "[WAIT] In attesa connessione controller… ($i/30)"
    sleep 1
  done

  echo "[ERROR] Timeout collegamento OpenFlow controller su ${BR_NAME}."
  exit 1
}


# =============================================
# Main
# =============================================
main() {
  # Debug: mostro subito interfacce e routing
  echo "[DEBUG] Prima di tutto, vedo interfacce e routing nel container OVS:"
  echo "  → Interfacce (solo IPv4):"
  ip -o -4 addr show
  echo "  → Routing:"
  ip route show
  echo "----------------------------------"

  # 1) Creo DB e directory e Avvio i demoni ovs
  prepare_ovs_db
  start_ovs

  # 2) Creo il bridge e aggiungo porte
  setup_data_bridge

  # 3) Imposto il controller e aspetto
  connect_controller
  wait_for_controller

  # 4) Flussi
  setup_flows

  echo "[INFO] Ports on $BR_NAME:"
  ovs-vsctl list-ports "$BR_NAME" || true
  echo "[INFO] Flows on $BR_NAME:"
  ovs-ofctl -O OpenFlow13 dump-flows "$BR_NAME" || true
  echo "[INFO] Controller:"; ovs-vsctl get-controller "$BR_NAME" || true
  ovs-vsctl show
  echo "[INFO] OVS container (${BR_NAME}) pronto. Rimango in foreground…"
  tail -f /dev/null
}

main
