#!/usr/bin/env bash
# One-time host setup for the RV-C CAN interface. Idempotent; run as root
# from the repo root:  sudo ./host/setup-can0.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

apt-get update -qq
apt-get install -y -qq can-utils iproute2

install -m 0644 "$HERE/can-modules.conf"   /etc/modules-load.d/can.conf
install -m 0644 "$HERE/80-can0.network"    /etc/systemd/network/80-can0.network
install -m 0755 "$HERE/wait-for-can.sh"    /usr/local/bin/wait-for-can.sh
install -d -m 0755 /etc/systemd/system/k3s.service.d
install -m 0644 "$HERE/k3s-wait-can0.conf" /etc/systemd/system/k3s.service.d/10-wait-can0.conf

modprobe -a can can_raw gs_usb
systemctl enable --now systemd-networkd
systemctl daemon-reload
networkctl reload
networkctl reconfigure can0 2>/dev/null || echo "can0 not present yet - plug in the adapter"

echo
ip -details -statistics link show can0 2>/dev/null | head -n 12 || true
echo
echo "Verify: expect 'bitrate 250000' and state UP above, then: candump can0"
