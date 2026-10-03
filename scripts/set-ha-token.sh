#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Store a Home Assistant long-lived access token for LibreCoach, restart it and
# check the token works through the Supervisor shim.
#
# Create the token first: Home Assistant -> your profile -> Security ->
# Long-lived access tokens -> Create token. Then, on the mini PC:
#   ./scripts/set-ha-token.sh                 (prompts; input is hidden)
#   HA_TOKEN=... ./scripts/set-ha-token.sh    (non-interactive, e.g. CI)
#
# The token lives only in the cluster Secret - never in git.
# -----------------------------------------------------------------------------
set -euo pipefail

NAMESPACE="${NAMESPACE:-rv-lab}"
RELEASE="${RELEASE:-rv-home-assistant}"
SECRET="${SECRET:-librecoach-ha-token}"

token="${HA_TOKEN:-}"
if [[ -z $token ]]; then
  read -rsp "Home Assistant long-lived access token: " token
  echo
fi
[[ -n $token ]] || { echo "no token given" >&2; exit 1; }

kubectl -n "$NAMESPACE" create secret generic "$SECRET" \
  --from-literal=token="$token" --dry-run=client -o yaml | kubectl apply -f -

# Environment variables are read at start, so restart both consumers.
kubectl -n "$NAMESPACE" rollout restart "deploy/$RELEASE-node-red" "deploy/$RELEASE-vehicle-bridge"
kubectl -n "$NAMESPACE" rollout status "deploy/$RELEASE-node-red" --timeout=300s

# Call Home Assistant exactly the way the flows do: http://supervisor/core/api/
# with SUPERVISOR_TOKEN, from inside the Node-RED pod.
echo "Checking http://supervisor/core/api/ from Node-RED ..."
kubectl -n "$NAMESPACE" exec "deploy/$RELEASE-node-red" -c node-red -- node -e '
  fetch("http://supervisor/core/api/", {
    headers: { Authorization: "Bearer " + process.env.SUPERVISOR_TOKEN },
  })
    .then(async (r) => { console.log(r.status, await r.text()); process.exit(r.ok ? 0 : 1); })
    .catch((e) => { console.error(e.message); process.exit(1); });
'
