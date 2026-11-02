#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# bootstrap.sh - deploy the RV-C Home Assistant stack onto the mini PC's K3s.
#
# Run on the mini PC AFTER the host has been set up by notlost-libre
# (node-provisioning/setup_node.sh: BIOS notes, OS tuning, CAN adapter, K3s),
# from a clone of this repo:
#   git clone https://github.com/ryanande/home-assistant.git
#   cd home-assistant && sudo ./bootstrap.sh
#
# What it does, in order:
#   1. preflight checks (root, x86_64, repo files, internet) and that the host
#      is ready: k3s active and the node Ready (warns if can0 is absent)
#   2. installs Argo CD and applies the root app, which deploys everything else
#   3. waits for Home Assistant and prints URLs, the Argo CD password and status
#
# It does not touch the host itself (timezone, sysctls, disk, firewall, CAN,
# K3s) - that all belongs to notlost-libre.
#
# Safe to re-run: every step checks before it changes anything.
#
# Settings (environment variables, e.g. `sudo WAIT_TIMEOUT=1800 ./bootstrap.sh`):
#   WAIT_TIMEOUT   seconds allowed per wait step       (default 900)
#   GITOPS_REVISION  git branch/tag Argo CD deploys    (default main). Anything
#                  else skips the root app and applies gitops/argocd/apps/*.yaml
#                  pinned to that revision - used by CI to test a branch.
# -----------------------------------------------------------------------------
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"
GITOPS_REVISION="${GITOPS_REVISION:-main}"

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

# The host (k3s, CAN) is set up by notlost-libre, not by this repo.
host_ready() {
  local hint="set the host up first: notlost-libre/node-provisioning/setup_node.sh"
  systemctl is-active -q k3s || die "k3s is not active; $hint"
  kubectl wait --for=condition=Ready node --all --timeout=60s >/dev/null 2>&1 \
    || die "the K3s node is not Ready (kubectl get node); $hint"
  ip link show can0 >/dev/null 2>&1 \
    || warn "can0 not found - plug in the SH-C31G; the CAN bridge stays idle until then (host CAN setup: notlost-libre)"
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
  for f in gitops/argocd/argocd-install.yaml gitops/argocd/root-app.yaml; do
    [[ -f $REPO_DIR/$f ]] || die "missing $f - run this from a clone of the repo"
  done
  curl -fsS --max-time 15 -o /dev/null https://github.com \
    || die "no internet access (https://github.com unreachable; Argo CD syncs from it)"
  host_ready
  info "$(nproc) CPU threads, $(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo) GiB RAM"
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
  if [[ $GITOPS_REVISION == main ]]; then
    log "Deploying apps from git (Argo CD root app)"
    kubectl apply -f "$REPO_DIR/gitops/argocd/root-app.yaml"
  else
    # The root app would re-sync the children back to main, so apply them
    # directly with targetRevision pointed at the branch under test.
    log "Deploying apps from git revision '$GITOPS_REVISION' (test mode, no root app)"
    local f
    for f in "$REPO_DIR"/gitops/argocd/apps/*.yaml; do
      sed "s|targetRevision: main|targetRevision: $GITOPS_REVISION|" "$f" | kubectl apply -f -
    done
  fi
  wait_for "the rv-home-assistant Application" kubectl -n argocd get application/rv-home-assistant
  wait_for "rv-home-assistant to sync from GitHub" app_synced rv-home-assistant
  wait_for "the MQTT broker" \
    kubectl -n rv-lab rollout status deploy/rv-home-assistant-mosquitto --timeout=5s
  info "Home Assistant's first start pulls a ~1.5 GB image; this can take several minutes"
  wait_for "Home Assistant" \
    kubectl -n rv-lab rollout status deploy/rv-home-assistant-home-assistant --timeout=5s
  wait_for "LibreCoach Node-RED (installs flow dependencies on first start)" \
    kubectl -n rv-lab rollout status deploy/rv-home-assistant-node-red --timeout=5s
}

summary() {
  local ip pw can bridge canstatus
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
  pw=$(kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  can=$(ip -details link show can0 2>/dev/null | grep -oE 'state [A-Z-]+|bitrate [0-9]+' | tr '\n' ' ' || true)
  bridge=$(kubectl -n rv-lab get pods -l app.kubernetes.io/component=vehicle-bridge --no-headers \
            2>/dev/null | awk '{print $3 " (restarts: " $4 ")"}' || true)
  canstatus=$(kubectl -n rv-lab exec deploy/rv-home-assistant-mosquitto -- \
            mosquitto_sub -t can/status -C 1 -W 5 2>/dev/null || true)

  log "Done"
  cat <<EOF

    Home Assistant   http://${ip:-<this-ip>}:8123     (create your owner account)
    Argo CD          https://${ip:-<this-ip>}:8443    (self-signed certificate)
                     user: admin   password: ${pw:-<already changed / secret deleted>}

    CAN can0         ${can:-not detected - plug in the SH-C31G (host CAN setup lives in notlost-libre)}
    vehicle_bridge   ${bridge:-not found}   can/status: ${canstatus:-<none yet>}

    Next steps
      1. Home Assistant: create your account, then Settings -> Devices & Services
         -> Add Integration -> MQTT
         broker: rv-home-assistant-mosquitto.rv-lab.svc.cluster.local   port: 1883
      2. LibreCoach: in Home Assistant, your profile -> Security -> Long-lived
         access tokens -> Create token, then:  ./scripts/set-ha-token.sh
      3. Argo CD: change the admin password (User Info), then
         kubectl -n argocd delete secret argocd-initial-admin-secret
      4. Check raw RV-C traffic:  candump can0
EOF
}

main() {
  if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    sed -n '3,/^# ---/{/^# ---/d;p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
  fi
  preflight
  install_argocd
  deploy_apps
  summary
}

main "$@"
