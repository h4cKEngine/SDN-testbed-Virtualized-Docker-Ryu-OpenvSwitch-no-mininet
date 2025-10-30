#!/bin/bash

################################################################################
# SCOPO
#   Inizializzare il piano di controllo SDN basato su Docker Swarm e creare
#   la rete overlay "control-net" a cui si connettono il controller Ryu,
#   gli switch OVS e i router. Lo script avvia inoltre i servizi Ryu tramite
#   Docker Compose.
#
# FUNZIONAMENTO
#   1. ensure_swarm()
#        - Verifica se il nodo ha già Docker Swarm attivo.
#        - Se non attivo, inizializza Swarm sul CONTROLLER_IP come manager.
#        - Mostra il token per permettere ad altri nodi di unirsi come worker.
#   2. ensure_overlay_net()
#        - Controlla se la rete overlay "control-net" esiste.
#        - Se non esiste, la crea con driver overlay, subnet 10.0.100.0/24,
#          gateway 10.0.100.1, e flag --attachable (accessibile ai container).
#        - Richiede che il nodo sia manager Swarm.
#   3. start_ryu()
#        - Rimuove eventuale container Ryu preesistente.
#        - Avvia i servizi definiti in docker-compose.yml (controller Ryu).
#   4. show_status()
#        - Mostra la lista dei container attivi e i dettagli della rete overlay.
#   5. show_join_token()
#        - Stampa il comando utile ai nodi worker per unirsi allo Swarm.
#
# USO
#   sudo ./control-net.sh
#
# RISULTATO
#   - Docker Swarm inizializzato e pronto (manager su CONTROLLER_IP).
#   - Rete overlay "control-net" creata e disponibile per switch, router e Ryu.
#   - Controller Ryu avviato tramite Docker Compose e collegato alla rete.
#   - Informazioni di stato e join-token stampate a schermo.
################################################################################


# =========================
# Configurazione
# =========================
CONTROLLER_IP="192.168.1.128"
CONTROL_NET="control-net"

ensure_swarm() {
  local state
  state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive)"

  if [[ "$state" == "active" ]]; then
    echo "✓ Swarm già inizializzato (stato: $state)."
  else
    echo "➜ Inizializzo Docker Swarm su $CONTROLLER_IP..."
    docker swarm init --advertise-addr "$CONTROLLER_IP"
    echo "✓ Swarm inizializzato."
  fi

  echo "➜ Controllo lo stato della rete '$CONTROL_NET'..."
  docker swarm join-token worker
}

# Crea overlay network attachable
ensure_overlay_net() {
  if docker network inspect "$CONTROL_NET" &>/dev/null; then
    echo "✓ Overlay '$CONTROL_NET' già esistente."
    return
  fi

  local is_control
  is_control="$(docker info --format '{{.Swarm.ControlAvailable}}')"
  if [[ "$is_control" != "true" ]]; then
    echo "! Nodo non-manager: impossibile creare overlay '$CONTROL_NET'."
    exit 1
  fi

  echo "➜ Creo overlay network '$CONTROL_NET'..."
  docker network create \
    --driver overlay \
    --subnet 10.0.100.0/24 \
    --gateway 10.0.100.1 \
    --attachable \
    "$CONTROL_NET"
  echo "✓ Overlay '$CONTROL_NET' creata.".
}

start_ryu() {
  docker rm -f ryu || true
  echo "➜ Avvio i servizi con Docker Compose ..."
  docker compose up -d --build
  echo "✓ Servizi avviati."
}


show_status() {
  echo
  echo "➜ Container attivi:"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}'
  echo
  echo "➜ Dettagli rete '$CONTROL_NET':"
  docker network inspect "$CONTROL_NET" | jq
}

show_join_token() {
  echo
  echo "➜ Comando per unire un nodo worker:"
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
