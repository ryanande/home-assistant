#!/usr/bin/env bash
# /usr/local/bin/wait-for-can.sh <iface> [timeout_seconds]
# Called from k3s ExecStartPre. Waits for the CAN link to be UP but never
# blocks K3s forever: if the adapter is missing, the rest of the cluster
# (Home Assistant, broker) still starts and the bridge pod simply crash-loops
# until the interface appears.
IFACE="${1:-can0}"
TIMEOUT="${2:-30}"
for ((i = 0; i < TIMEOUT; i++)); do
  if ip -details link show "$IFACE" 2>/dev/null | grep -q '[<,]UP[,>]'; then
    echo "wait-for-can: $IFACE is up"
    exit 0
  fi
  sleep 1
done
echo "wait-for-can: WARNING $IFACE not up after ${TIMEOUT}s, starting k3s anyway" >&2
exit 0
