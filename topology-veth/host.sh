#!/bin/bash

################################################################################
# SCOPO
#   Inizializzare un container host della topologia SDN, configurandone
#   automaticamente l’interfaccia di rete (eth0) e il gateway predefinito
#   in base alle variabili d’ambiente ricevute.
#
# FUNZIONAMENTO
#   • Attende che l’interfaccia eth0 sia creata e collegata da topology.sh
#     tramite coppia veth ↔ OVS.
#   • Configura l’indirizzo IP:
#       – Legge la variabile HOST_IP.
#       – Se manca la maschera CIDR, assume /24 di default.
#       – Aggiunge l’indirizzo a eth0 e porta l’interfaccia up.
#   • Configura il gateway predefinito:
#       – Legge la variabile DEFAULT_GW.
#       – Se presente, aggiunge/aggiorna la route di default via quel gateway.
#   • Stampa lo stato IP dell’interfaccia.
#   • Rimane in idle (`tail -f /dev/null`) mantenendo vivo il container.
#
# RUOLO
#   Ogni container host rappresenta un endpoint della rete SDN,
#   utile per testare connettività, ping, traceroute e flussi gestiti dal
#   controller Ryu attraverso gli switch OVS.
#
# RISULTATO
#   Un host containerizzato pronto all’uso, configurato con IP e gateway
#   corretti, e collegato al proprio switch di accesso nella topologia.
################################################################################


# ====================================================
# Script di inizializzazione per il container "host"
# ====================================================
#  - Aspetta che compaia eth0 (montata da topology.sh)
#  - Legge HOST_IP e DEFAULT_GW come variabili d'ambiente
#  - Configura IP e gateway, poi rimane in idle

configure_interface() {
  DATA_IFACE="eth0"

  echo "[DEBUG] Attendo che compaia l'interfaccia $DATA_IFACE..."

  # Aspetto indefinitamente che eth0 sia montata
  while ! ip link show dev "$DATA_IFACE" &> /dev/null; do
    sleep 0.5
  done
  echo "[INFO] Interfaccia $DATA_IFACE trovata."

  # Ora configuro l'IP
  echo "[INFO] Configuro IP su $DATA_IFACE..."

  if [ -n "${HOST_IP:-}" ]; then
    IP_WITH_CIDR="$HOST_IP"
    # Se manca la maschera, aggiungo /24 di default
    if [[ ! "$HOST_IP" =~ "/" ]]; then
      IP_WITH_CIDR="${HOST_IP}/24"
    fi

    echo "[INFO] Imposto IP $IP_WITH_CIDR su $DATA_IFACE"
    if ! ip addr show dev "$DATA_IFACE" | grep -q "${HOST_IP%%/*}"; then
      ip addr add "$IP_WITH_CIDR" dev "$DATA_IFACE"
    else
      echo "[INFO] IP $IP_WITH_CIDR già presente"
    fi
    ip link set dev "$DATA_IFACE" up
  else
    echo "[WARN] Variabile HOST_IP non settata: salto assegnazione IP"
  fi
}

configure_gateway() {
  if [ -n "${DEFAULT_GW:-}" ]; then
    echo "[INFO] Configuro gateway predefinito: via $DEFAULT_GW"
    ip route replace default via "$DEFAULT_GW" dev eth0
  else
    echo "[WARN] DEFAULT_GW non settata: salto configurazione gateway"
  fi
}

main() {
  echo "[INFO] Inizio configurazione host $(hostname)…"
  configure_interface
  configure_gateway

  echo "[INFO] Stato IP su eth0:"
  ip -4 addr show dev eth0 || true

  echo "[INFO] Host pronto. Rimango in idle…"
  exec tail -f /dev/null
}

main "$@"
