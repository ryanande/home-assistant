#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# bootstrap.sh - fresh install of the RV-C Home Assistant lab on a new mini PC.
#
# Run on a freshly installed Ubuntu Server 24.04 LTS, from a clone of this repo:
#   git clone https://github.com/ryanande/home-assistant.git
#   cd home-assistant && sudo ./bootstrap.sh
#
# What it does, in order:
#   1. preflight checks (root, x86_64, Ubuntu 24.04, internet)
#   2. base packages, host timezone, inotify limits
#   3. grows the LVM root volume into the unused disk (Ubuntu only uses 100 GiB)
#   4. opens firewall ports if ufw is active
#   5. host CAN setup (host/setup-can0.sh) - fine if the adapter isn't plugged in
#   6. installs K3s and gives your login user kubectl access
#   7. installs Argo CD and applies the root app, which deploys everything else
#   8. waits for Home Assistant and prints URLs, the Argo CD password and status
#
# Safe to re-run: every step checks before it changes anything.
#
# Settings (environment variables, e.g. `sudo HOST_TIMEZONE=America/Denver ./bootstrap.sh`):
#   HOST_TIMEZONE  host clock timezone                 (default America/Chicago)
#   K3S_CHANNEL    K3s release channel                 (default stable)
#   K3S_VERSION    exact K3s version, e.g. v1.34.1+k3s1 (default: latest on channel)
#   EXTEND_ROOT    grow the root volume: yes|no        (default yes)
#   WAIT_TIMEOUT   seconds allowed per wait step       (default 900)
# -----------------------------------------------------------------------------
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOST_TIMEZONE="${HOST_TIMEZONE:-America/Chicago}"
K3S_CHANNEL="${K3S_CHANNEL:-stable}"
K3S_VERSION="${K3S_VERSION:-}"
EXTEND_ROOT="${EXTEND_ROOT:-yes}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"

MANIFESTS=/var/lib/rancher/k3s/server/manifests
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="/usr/local/bin:$PATH"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    WARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND (safe to fix and re-run)"' ERR

# wait_for <description> <command...>: retry every 5s until it succeeds.
wait_for() {
  local desc=$1; shift
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  info "waiting for $desc ..."
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "timed out after ${WAIT_TIMEOUT}s waiting for $desc"
    sleep 5
  done
}

app_synced() {
  [[ $(kubectl -n argocd get application "$1" -o jsonpath='{.status.sync.status}') == Synced ]]
}

preflight() {
  log "Preflight checks"
  [[ $EUID -eq 0 ]] || die "run with sudo: sudo ./bootstrap.sh"
  [[ $(uname -m) == x86_64 ]] || die "expected an x86_64 host, found $(uname -m)"
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 ]]; then
    warn "built for Ubuntu 24.04, found ${PRETTY_NAME:-unknown}; continuing"
  fi
  local f
  for f in host/setup-can0.sh gitops/argocd/argocd-install.yaml gitops/argocd/root-app.yaml; do
    [[ -f $REPO_DIR/$f ]] || die "missing $f - run this from a clone of the repo"
  done
  curl -fsS --max-time 15 -o /dev/null https://get.k3s.io \
    || die "no internet access (https://get.k3s.io unreachable)"
  info "$(nproc) CPU threads, $(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo) GiB RAM"
}

base_system() {
  log "Base packages and host settings"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl git jq >/dev/null
  timedatectl set-timezone "$HOST_TIMEZONE"
  info "timezone: $HOST_TIMEZONE"
  # K3s, Argo CD and Home Assistant together exceed Ubuntu's default of 128
  # inotify instances, which shows up as "too many open files" in pod logs.
  cat > /etc/sysctl.d/90-rv-lab.conf <<'EOF'
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 524288
EOF
  sysctl -q --system
}

extend_root() {
  [[ $EXTEND_ROOT == yes ]] || return 0
  local src vg free_g
  src=$(findmnt -no SOURCE /)
  if ! lvs "$src" >/dev/null 2>&1; then
    info "root filesystem is not on LVM; nothing to grow"
    return 0
  fi
  vg=$(lvs --noheadings -o vg_name "$src" | tr -d ' ')
  free_g=$(vgs --noheadings --units g --nosuffix -o vg_free "$vg" | tr -d ' ')
  free_g=${free_g%.*}
  if (( ${free_g:-0} >= 5 )); then
    log "Growing the root volume into ${free_g} GiB of unused disk"
    info "Ubuntu's installer caps / at 100 GiB; K3s volumes (HA config, database) live on /"
    lvextend -q -r -l +100%FREE "$src"
  fi
  info "/ is now $(df -h --output=size / | tail -1 | tr -d ' ')"
}

firewall() {
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    log "ufw is active - opening ports"
    ufw allow 22/tcp comment 'SSH' >/dev/null
    ufw allow 8123/tcp comment 'Home Assistant' >/dev/null
    ufw allow 8443/tcp comment 'Argo CD' >/dev/null
    ufw allow from 10.42.0.0/16 comment 'K3s pods' >/dev/null
    ufw allow from 10.43.0.0/16 comment 'K3s services' >/dev/null
  fi
}

can_interface() {
  log "CAN interface"
  # Installs the networkd config and the k3s.service drop-in BEFORE K3s
  # exists, so K3s starts after can0 from its very first boot.
  "$REPO_DIR/host/setup-can0.sh"
}

install_k3s() {
  log "K3s"
  if systemctl is-active -q k3s; then
    info "already running: $(k3s --version | head -1)"
  else
    # INSTALL_K3S_VERSION, when set, takes precedence over the channel.
    curl -sfL https://get.k3s.io \
      | INSTALL_K3S_CHANNEL="$K3S_CHANNEL" INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server
  fi
  wait_for "the K3s API" kubectl get --raw /readyz
  wait_for "the node to be Ready" kubectl wait --for=condition=Ready node --all --timeout=5s

  # Let the login user run kubectl without sudo.
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    local home group
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    group=$(id -gn "$SUDO_USER")
    install -d -m 0700 -o "$SUDO_USER" -g "$group" "$home/.kube"
    install -m 0600 -o "$SUDO_USER" -g "$group" /etc/rancher/k3s/k3s.yaml "$home/.kube/config"
    grep -qs 'KUBECONFIG=' "$home/.bashrc" \
      || echo 'export KUBECONFIG=$HOME/.kube/config' >> "$home/.bashrc"
    info "kubectl configured for $SUDO_USER (open a new shell to pick it up)"
  fi
}

install_argocd() {
  log "Argo CD"
  install -m 0644 "$REPO_DIR/gitops/argocd/argocd-install.yaml" "$MANIFESTS/argocd.yaml"
  wait_for "the Argo CD CRDs" \
    kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=5s
  wait_for "the Argo CD deployments to be created" kubectl -n argocd get deploy/argocd-server
  kubectl -n argocd rollout status deploy/argocd-server --timeout="${WAIT_TIMEOUT}s"
  kubectl -n argocd rollout status deploy/argocd-repo-server --timeout="${WAIT_TIMEOUT}s"
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout="${WAIT_TIMEOUT}s"
}

deploy_apps() {
  log "Deploying apps from git (Argo CD root app)"
  kubectl apply -f "$REPO_DIR/gitops/argocd/root-app.yaml"
  wait_for "the rv-home-assistant Application" kubectl -n argocd get application/rv-home-assistant
  wait_for "rv-home-assistant to sync from GitHub" app_synced rv-home-assistant
  wait_for "the MQTT broker" \
    kubectl -n rv-lab rollout status deploy/rv-home-assistant-mosquitto --timeout=5s
  info "Home Assistant's first start pulls a ~1.5 GB image; this can take several minutes"
  wait_for "Home Assistant" \
    kubectl -n rv-lab rollout status deploy/rv-home-assistant-home-assistant --timeout=5s
}

summary() {
  local ip pw can bridge
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
  pw=$(kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  can=$(ip -details link show can0 2>/dev/null | grep -oE 'state [A-Z-]+|bitrate [0-9]+' | tr '\n' ' ' || true)
  bridge=$(kubectl -n rv-lab get pods -l app.kubernetes.io/component=can-bridge --no-headers \
            2>/dev/null | awk '{print $3 " (restarts: " $4 ")"}' || true)

  log "Done"
  cat <<EOF

    Home Assistant   http://${ip:-<this-ip>}:8123     (create your owner account)
    Argo CD          https://${ip:-<this-ip>}:8443    (self-signed certificate)
                     user: admin   password: ${pw:-<already changed / secret deleted>}

    CAN can0         ${can:-not detected - plug in the SH-C31G, then: sudo networkctl reconfigure can0}
    CAN bridge pod   ${bridge:-not found}

    Next steps
      1. Home Assistant: Settings -> Devices & Services -> Add Integration -> MQTT
         broker: rv-home-assistant-mosquitto.rv-lab.svc.cluster.local   port: 1883
      2. Argo CD: change the admin password (User Info), then
         kubectl -n argocd delete secret argocd-initial-admin-secret
      3. Check raw RV-C traffic:  candump can0
EOF
}

main() {
  if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    sed -n '3,/^# ---/{/^# ---/d;p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
  fi
  preflight
  base_system
  extend_root
  firewall
  can_interface
  install_k3s
  install_argocd
  deploy_apps
  summary
}

main "$@"
