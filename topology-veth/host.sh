#!/bin/bash

################################################################################
# SCOPE
#   Initialize an SDN topology host container, automatically configuring
#   its network interface (eth0) and default gateway.
#   based on received environment variables.
#
# OPERATION
#   - Waits for the eth0 interface to be created and connected by topology.sh
#     via veth <-> OVS pair.
#   - Configures the IP address:
#       - Reads the HOST_IP variable.
#       - If CIDR mask is missing, assumes /24 by default.
#       - Adds the address to eth0 and brings the interface up.
#   - Configures the default gateway:
#       - Reads the DEFAULT_GW variable.
#       - If present, adds/updates the default route via that gateway.
#   - Prints the interface IP state.
#   - Remains in idle (`tail -f /dev/null`) keeping the container alive.
#
# ROLE
#   Each host container represents an SDN network endpoint,
#   useful for testing connectivity, ping, traceroute, and flows managed by the
#   Ryu controller through OVS switches.
#
# RESULT
#   A ready-to-use containerized host, configured with correct IP and gateway,
#   and connected to its access switch in the topology.
################################################################################


# ====================================================
# Initialization script for the "host" container
# ====================================================
#  - Waits for eth0 to appear (mounted by topology.sh)
#  - Reads HOST_IP and DEFAULT_GW as environment variables
#  - Configures IP and gateway, then remains in idle

configure_interface() {
  DATA_IFACE="eth0"

  echo "[DEBUG] Waiting for interface $DATA_IFACE to appear..."

  # Wait indefinitely for eth0 to be mounted
  while ! ip link show dev "$DATA_IFACE" &> /dev/null; do
    sleep 0.5
  done
  echo "[INFO] Interface $DATA_IFACE found."

  # Now configure the IP
  echo "[INFO] Configuring IP on $DATA_IFACE..."

  if [ -n "${HOST_IP:-}" ]; then
    IP_WITH_CIDR="$HOST_IP"
    # If mask is missing, add /24 by default
    if [[ ! "$HOST_IP" =~ "/" ]]; then
      IP_WITH_CIDR="${HOST_IP}/24"
    fi

    echo "[INFO] Setting IP $IP_WITH_CIDR on $DATA_IFACE"
    if ! ip addr show dev "$DATA_IFACE" | grep -q "${HOST_IP%%/*}"; then
      ip addr add "$IP_WITH_CIDR" dev "$DATA_IFACE"
    else
      echo "[INFO] IP $IP_WITH_CIDR already present"
    fi
    ip link set dev "$DATA_IFACE" up
  else
    echo "[WARN] HOST_IP variable not set: skipping IP assignment"
  fi
}

configure_gateway() {
  if [ -n "${DEFAULT_GW:-}" ]; then
    echo "[INFO] Configuring default gateway: via $DEFAULT_GW"
    ip route replace default via "$DEFAULT_GW" dev eth0
  else
    echo "[WARN] DEFAULT_GW not set: skipping gateway configuration"
  fi
}

main() {
  echo "[INFO] Starting host host $(hostname)..."
  configure_interface
  configure_gateway

  echo "[INFO] IP state on eth0:"
  ip -4 addr show dev eth0 || true

  echo "[INFO] Host ready. Staying in idle..."
  exec tail -f /dev/null
}

main "$@"
