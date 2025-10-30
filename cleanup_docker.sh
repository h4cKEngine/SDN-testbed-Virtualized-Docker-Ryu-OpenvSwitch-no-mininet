#!/bin/bash

# ==============================================================================
# Script di CLEANUP TOTALE per ambiente SDN containerizzato
# ==============================================================================
# Scopo
#   Rimuovere in modo aggressivo TUTTI i componenti dell’ambiente di test
#   (container, reti, immagini, volumi, risorse OVS e interfacce residue), così
#   da riportare l’host ad uno stato “pulito” prima di un nuovo deploy.
#
# ATTENZIONE (operazioni DISTRUTTIVE)
#   - Elimina container, reti custom, volumi orfani e (opz.) TUTTE le immagini.
#   - Esegue `docker system prune -a -f` e `docker builder prune -a -f`.
#   - Cancella veth/gre residue a livello host e nei netns dei container.
#   - Interviene su OVS: ferma demoni, elimina bridge/interfacce, ripulisce DB.
#   - Riavvia i servizi openvswitch-switch e docker.
#   PROSEGUIRE SOLO SE si intende davvero resettare l’intero ambiente.
#
# Uso
#   sudo ./<script>.sh
#   (non accetta parametri)
#
# Prerequisiti
#   - Privilegi root.
#   - Docker + Docker Compose, Open vSwitch, iproute2, nsenter, awk/sed/grep.
#   - Nomi delle interfacce di base correttamente esclusi dai filtri:
#       lo | enp3s0 | wlo1 | virbr0 | docker0
#     (adattare l’elenco alla macchina ospitante, se necessario).
#
# Cosa fa, in ordine:
#   1) Esce dallo Swarm (worker): `docker swarm leave --force`.
#   2) Rimuove controller Ryu e overlay di controllo `control-net`.
#   3) Arresta e rimuove TUTTI i container (non solo h*/ovs*).
#   4) Rimuove eventuali reti dati “bridge” generate per host-switch/switch-switch.
#   5) Esegue `docker compose down -v --remove-orphans`, prune di container/volumi.
#   6) Ripulisce reti custom orfane (`docker network prune` + delete mirate).
#   7) Prune avanzato di sistema e builder.
#   8) (Opzionale ma attivo) Rimuove tutte le immagini Docker locali.
#   9) Porta l’interfaccia fisica principale in promisc (enp3s0), se serve.
#  10) Cancella interfacce residue a livello host (veth/bridge/ovs) eccetto quelle
#      essenziali; prova a rimuovere gre0/gretap0/erspan0 (template non rimovibili).
#  11) Rimuove bridge OVS residui (ovs-system, br-*), killer dei demoni OVS,
#      cleanup di vxlan-br/br-vxlan/vxlan0 e di veth-router*.
#  12) Pulisce le interfacce veth residue all’interno dei container (via nsenter).
#  13) Esegue un restart “pulito” di Open vSwitch:
#       - stop demoni, kill processi, delete vxlan*, purge run/log/conf.db.*,
#         start servizio openvswitch-switch.
#  14) Riavvia Docker e stampa lo stato finale (container/reti/volumi/usage Disco),
#      oltre all’assetto IP dell’host.
#
# Note operative
#   - Idempotenza: ogni step è “best effort” (|| true) per tollerare stati parziali.
#   - Sicurezza: rivedere i filtri delle interfacce escluse prima dell’uso; non
#     rimuovere link fisici/gestionali dell’host.
#   - Conservazione immagini: per conservare le immagini locali, commentare
#     `remove_all_images` e/o `advanced_cleanup`.
#   - Ambiente OVS: il blocco di restart rimuove socket/lock/log/DB residui che
#     possono impedire ripartenze pulite dopo test intensivi.
#
# Output atteso
#   - Nessun container attivo, nessuna rete custom residua, OVS in stato “fresh”.
#   - Stato stampato a fine esecuzione: `docker ps -a`, `docker network ls`,
#     `docker volume ls`, `docker system df`, `ip -4 a`.
#
# Responsabilità
#   Questo script è pensato per ambienti di laboratorio. Evitarne l’uso su host
#   di produzione o con risorse Docker condivise.
# ==============================================================================


# ====================================================
# Funzioni di cleanup Docker
# ====================================================
stop_and_remove_containers() {
  echo "[1/8] Arresto e rimozione container di host e switches…"
  #docker ps -a --filter "name=^h[0-9]+" --format "{{.ID}}" | xargs -r docker rm -f
  docker ps -a | xargs -r docker rm -f # Comprende anche altri nomi
}

remove_controller_and_controlnet() {
  echo "[2/8] Rimozione container Ryu e rete di controllo..."
  docker rm -f ryu || true
  docker network rm control-net || true
}

remove_data_networks() {
  echo -e "\n[3/8] Rimozione reti dati topology (host-switch e switch-switch)..."
  docker network ls --filter "driver=bridge" --format "{{.Name}}" \
    | grep -E '^(h[0-9]+s[0-9]+-net|s[0-9]+s[0-9]+-net)$' \
    | xargs -r docker network rm || true
}

remove_orphan_resources() {
  echo -e "\n[4/8] Rimozione container e volumi orfani..."
  docker compose down -v --remove-orphans || true
  docker container prune -f || true
  docker volume prune -f || true
}

remove_custom_networks() {
  echo -e "\n[5/8] Rimozione reti orfane e custom (eccetto bridge, host, none)..."
  docker network prune -f
  docker network ls --filter "type=custom" -q | xargs -r docker network rm || true
}

advanced_cleanup() {
  echo -e "\n[6/8] Pulizia avanzata di sistema Docker..."
  docker system prune -a -f || true
  docker builder prune -a -f || true
}

remove_all_images() {
  echo -e "\n[7/8] Rimozione di tutte le immagini Docker..."
  docker image prune -a -f
  docker images -q | xargs -r docker rmi -f || true
}

delete_veth_and_gre_interfaces() {
  echo -e "\n[8/8] Rimozione interfacce residue tranne quelle di base…"

  # 1) elimina tutte le interfacce non essenziali (veth, bridge docker, ovs, ecc.)
  ip -o link show \
    | awk -F': ' '{print $2}' \
    | sed 's/@.*//' \
    | grep -Ev '^(lo|enp3s0|wlo1|virbr0|docker0)$' \
    | sort -u \
    | while read -r iface; do
        echo "  Eliminazione di $iface…"
        ip link delete "$iface" 2>/dev/null || true
      done

  # 2) rimuovi le GRE di sistema se ancora presenti
  for gre_if in gre0 gretap0 erspan0; do
    if ip link show "$gre_if" &>/dev/null; then
      echo "  Eliminazione interfaccia GRE $gre_if…"
      ip link delete "$gre_if" 2>/dev/null || true
    fi
  done

  # 3) ferma ovs-vswitchd e scarica il modulo GRE
  pkill ovs-vswitchd 2>/dev/null || true
  modprobe -r ip_gre 2>/dev/null || true
  
  echo "  [INFO] Le interfacce gre0, gretap0, erspan0 sono kernel template e NON sono removibili manualmente."
  echo "[OK] Interfacce di rete e GRE pulite."
}

# ====================================================
# 9) Rimuove i bridge OVS residui (ovs-system e br-*)
# ====================================================
delete_remaining_ovs_bridges() {
  echo -e "\n[9/9] Rimozione restanti bridge OVS (ovs-system e br-*)…"
  systemctl restart openvswitch-switch

  # 1) Assicuriamoci che i demoni OVS non stiano ricreando le interfacce
  pkill ovsdb-server ovs-vswitchd 2>/dev/null || true

  # 2) Elimino direttamente ovs-system (se esiste)
  if ip link show ovs-system &>/dev/null; then
    echo "  Eliminazione interfaccia ovs-system…"
    ip link delete ovs-system 2>/dev/null || true
  fi

  # 3) Trovo e distruggo tutti i bridge che iniziano con 'br-'
  for br in $(ip -o link show \
               | awk -F': ' '{print $2}' \
               | sed 's/@.*//' \
               | grep -E '^br-'); do
    echo "  Eliminazione bridge $br…"
    # prova prima con ovs-vsctl (se il database è ancora vivo)
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

  echo "[OK] Tutti i bridge OVS residui sono stati rimossi."
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

  # ATTENZIONE: elimina i socket e lock residui!
  rm -rf /var/run/openvswitch/*
  rm -rf /var/log/openvswitch/*
  rm -rf /etc/openvswitch/conf.db.*
  sleep 2
  sudo systemctl start openvswitch-switch
}

cleanup_veth_in_container() {
  echo -e "\n[10/10] Pulizia interfacce veth residue nei container…"

  docker ps -q | while read -r cid; do
    cname=$(docker inspect -f '{{.Name}}' "$cid" | cut -c2-)
    echo "  🔍 Container: $cname"

    PID=$(docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null)
    if [[ "$PID" =~ ^[0-9]+$ ]] && [[ "$PID" -gt 0 ]]; then
      nsenter -t "$PID" -n ip -o link show \
        | awk -F': ' '{print $2}' \
        | sed 's/@.*//' \
        | grep -Ev '^(lo|eth0|eth1|ovsbr|vxlan0|ovs-system)$' \
        | while read -r iface; do
            echo "    🧹 Elimino $iface…"
            nsenter -t "$PID" -n ip link delete "$iface" 2>/dev/null || true
        done
    else
      echo "    ⚠️ PID non valido ($PID) per container $cname"
    fi
  done
  echo "[OK] Cleanup interfacce container completato."
}


# ====================================================
# Main
# ====================================================
main() {
  echo "Esco dalla rete overlay docker swarm (da worker)"
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

  echo -e "\nStato finale dei container:"
  docker ps --all

  echo -e "\nStato finale delle reti:"a
  docker network ls

  echo -e "\nStato finale dei volumi:"
  docker volume ls

  echo -e "\nUtilizzo disco Docker:"
  docker system df

  ip -4 a
}

main "$@"
