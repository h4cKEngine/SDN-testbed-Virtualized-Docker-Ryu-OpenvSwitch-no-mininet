#!/bin/bash

set -euo pipefail

# - Registra gli host presso il controller Ryu (/register_host) inferendo dpid/port
#   dal nome porta OVS (peer_<host>, ecc).
# - Crea coppie consentite simmetriche (/pair) in base all'elenco di host.
# - Sorgenti degli host:
#     1) Variabile TOPOLOGY (se definita qui in base a TOPOLOGY_NO o exportata da fuori)
#     2) Altrimenti autodiscovery dei container docker hN
#
# Uso:
#   ./register_hosts.sh               # sync completo (hosts + pairs)
#   ./register_hosts.sh 1             # forza TOPOLOGY_NO=1
#   TOPOLOGY_NO=2 ./register_hosts.sh # idem via env
#
# Requisiti: curl, jq, docker

# Config minima: sovrascrivibile via env
: "${CONTROLLER_IP:=192.168.1.128}"
: "${CONTROLLER_REST_PORT:=8080}"
: "${TOPOLOGY_NO:=1}"

# Se viene passato un argomento numerico, ha precedenza su env
if [[ "${BASH_SOURCE[0]}" == "$0" && $# -ge 1 ]]; then
  TOPOLOGY_NO="$1"
fi

CONTROLLER_URL="http://${CONTROLLER_IP}:${CONTROLLER_REST_PORT}"

# (Opzionale) Definizione interna della TOPOLOGY in base a TOPOLOGY_NO.
# Se preferisci iniettare TOPOLOGY da fuori (source/export), commenta questo blocco.
if [[ "${TOPOLOGY_NO}" == 1 ]]; then
  declare -a TOPOLOGY=(
    "h1 10.0.1.1/24"
    "h2 10.0.1.2/24"
    "h3 10.0.1.3/24"
    "h4 10.0.1.4/24"
    "h5 10.0.1.5/24"
    "h6 10.0.1.6/24"
    "h7 10.0.1.7/24"
    "h8 10.0.1.8/24"
  )
elif [[ "${TOPOLOGY_NO}" == 2 ]]; then
  declare -a TOPOLOGY=(
    "h9 10.0.2.9/24"
    "h10 10.0.2.10/24"
    "h11 10.0.2.11/24"
    "h12 10.0.2.12/24"
    "h13 10.0.2.13/24"
    "h14 10.0.2.14/24"
    "h15 10.0.2.15/24"
    "h16 10.0.2.16/24"
  )
fi

need() { command -v "$1" >/dev/null || { echo "[ERROR] missing '$1'"; exit 1; }; }
need curl
need jq
need docker

wait_for_controller() {
  local tries=30
  while ((tries--)); do
    curl -fsS "${CONTROLLER_URL}/pairs" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "[WARN] REST Ryu non raggiungibile su ${CONTROLLER_URL}."
  return 1
}

# Lista host tipo h1, h2, ... ordinati naturalmente
discover_hosts() {
  docker ps --format '{{.Names}}' \
  | grep -E '^h[0-9]+$' \
  | sort -V
}

# IP dell'host (da eth0; fallback env HOST_IP)
host_ip() {
  local h="$1"
  local ip
  ip="$(docker exec "$h" sh -c "ip -4 -o addr show dev eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" || true)"
  [[ -z "$ip" ]] && ip="$(docker exec "$h" printenv HOST_IP 2>/dev/null | cut -d/ -f1 || true)"
  echo "$ip"
}

ryu_sync_topology() {
  echo "[INFO] Fetch stato Ryu…"
  local SWJSON HOSTMAP PAIRJSON
  SWJSON="$(curl -fsS "${CONTROLLER_URL}/v1.0/topology/switches" || echo '[]')"
  HOSTMAP="$(curl -fsS "${CONTROLLER_URL}/hostmap" || echo '[]')"
  PAIRJSON="$(curl -fsS "${CONTROLLER_URL}/pairs" || echo '{"pairs":[]}')"

  # ---- indice porta: trova (dpid,port_no) dal nome porta che contiene l'hostname
  lookup_port() {
    local host_lc="$1"
    jq -r --arg h "$host_lc" '
      .[]? as $sw
      | ($sw.ports // [])[]? as $p
      | ($p.name // "" | ascii_downcase) as $n
      | select(
          $n==$h or
          $n=="peer_"+$h or
          $n=="peer-"+$h or
          $n==($h+"_peer") or
          $n==($h+"-peer") or
          ($n|contains($h))
        )
      | "\($sw.dpid),\($p.port_no|tostring|tonumber),\($p.name)"
    ' <<< "$SWJSON"
  }

  # ---- host già registrato correttamente?
  host_is_current() {
    local ip="$1" host="$2" dpid="$3" port="$4"
    jq -e --arg ip "$ip" --arg h "$host" --arg dpid "$dpid" --argjson port "$port" '
      .[]? | select(.ip==$ip)
      | select((.hostname==$h) and (.dpid==$dpid) and ((.port|tonumber)==$port))
    ' >/dev/null 2>&1 <<< "$HOSTMAP"
  }

  ensure_host() {
    local ip="$1" host="$2"
    local hkey; hkey="$(tr '[:upper:]' '[:lower:]' <<< "$host")"

    local matches; matches="$(lookup_port "$hkey" || true)"
    if [[ -z "$matches" ]]; then
      echo "[WARN] Nessuna porta trovata per $host ($ip). Attesi nomi tipo 'peer_${host}' sugli OVS."
      return 1
    fi
    local line; line="$(grep -i 'peer' <<< "$matches" | head -n1 || head -n1 <<< "$matches")"
    local dpid port_no port_name
    dpid="$(cut -d, -f1 <<< "$line")"
    port_no="$(cut -d, -f2 <<< "$line")"
    port_name="$(cut -d, -f3- <<< "$line")"

    if host_is_current "$ip" "$host" "$dpid" "$port_no"; then
      echo "  ✓ $host già registrato (dpid=$dpid port=$port_no - $port_name)"
      return 0
    fi

    local json; json=$(printf '{"ip":"%s","port":%d,"hostname":"%s","dpid":"%s"}' "$ip" "$port_no" "$host" "$dpid")
    echo "  → registro $host ($ip) dpid=$dpid port=$port_no ($port_name)"
    curl -fsS -X POST -H "Content-Type: application/json" -d "$json" \
         "${CONTROLLER_URL}/register_host" >/dev/null || return 1

    # aggiorna cache locale (best-effort)
    HOSTMAP="$(jq -c --arg ip "$ip" --arg h "$host" --arg dpid "$dpid" --argjson port "$port_no" '
      . as $arr
      | ([$arr[]? | select(.ip!=$ip)]) + [ {ip:$ip, hostname:$h, dpid:$dpid, port:$port} ]
    ' <<< "${HOSTMAP:-[]}" 2>/dev/null || echo "[]")"
  }

  # ---- coppia già presente?
  pair_exists() {
    local src="$1" dst="$2"
    jq -e --arg s "$src" --arg d "$dst" '
      .pairs? // [] | .[] | select(.src==$s and .dst==$d)
    ' >/dev/null 2>&1 <<< "$PAIRJSON"
  }

  ensure_pair() {
    local src="$1" dst="$2"
    if pair_exists "$src" "$dst"; then
      echo "  ✓ pair $src → $dst già presente"
      return 0
    fi
    local json; json=$(printf '{"src":"%s","dst":"%s"}' "$src" "$dst")
    echo "  → allow $src → $dst"
    curl -fsS -X POST -H "Content-Type: application/json" -d "$json" \
         "${CONTROLLER_URL}/pair" >/dev/null || return 1
    PAIRJSON="$(jq -c --arg s "$src" --arg d "$dst" '
      .pairs = ((.pairs? // []) + [{src:$s,dst:$d}])
    ' <<< "${PAIRJSON:-{}}" 2>/dev/null || echo '{"pairs":[]}')"
  }

  # ======= RACCOLTA HOST: TOPOLOGY -> fallback autodiscovery =======
  echo "[INFO] Raccolgo host…"
  declare -a HOSTS=()
  declare -A IP_BY_HOST=()

  if declare -p TOPOLOGY &>/dev/null && ((${#TOPOLOGY[@]})); then
    # Supporta sia "host ip/cidr" sia "host ovs br ip/cidr gw"
    for e in "${TOPOLOGY[@]}"; do
      set -- $e
      host="$1"
      ipcidr=""
      if   [[ $# -ge 4 ]]; then ipcidr="$4"
      elif [[ $# -ge 2 ]]; then ipcidr="$2"
      else continue; fi
      HOSTS+=("$host")
      IP_BY_HOST["$host"]="${ipcidr%/*}"
    done
  else
    mapfile -t HOSTS < <(discover_hosts)
    if ((${#HOSTS[@]}==0)); then
      echo "[WARN] Nessun container host trovato (pattern ^h[0-9]+$)."
      return 0
    fi
    for h in "${HOSTS[@]}"; do
      ip="$(host_ip "$h")"
      if [[ -n "$ip" ]]; then
        IP_BY_HOST["$h"]="$ip"
      else
        echo "[WARN] IP non rilevato per $h (eth0 non pronto?)."
      fi
    done
  fi
  # ================================================================

  echo "[INFO] Registro host (idempotente)…"
  for h in "${HOSTS[@]}"; do
    ip="${IP_BY_HOST[$h]:-}"
    [[ -z "$ip" ]] && continue
    ensure_host "$ip" "$h" || true
  done

  echo "[INFO] Installo allowed pairs simmetriche…"
  local n="${#HOSTS[@]}"
  for ((i=0; i<n/2; i++)); do
    local A="${HOSTS[i]}" B="${HOSTS[n-1-i]}"
    local IPA="${IP_BY_HOST[$A]:-}" IPB="${IP_BY_HOST[$B]:-}"
    [[ -z "$IPA" || -z "$IPB" ]] && continue
    ensure_pair "$IPA" "$IPB"
    ensure_pair "$IPB" "$IPA"
  done

  echo "[OK] Sync completo."
}

wait_for_controller || echo "[WARN] procedo comunque"
ryu_sync_topology
