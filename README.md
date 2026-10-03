# home-assistant — RV-C lab on K3s

Umbrella Helm chart (`charts/rv-home-assistant`) deploying Mosquitto, the LibreCoach
CAN→MQTT bridge and Home Assistant Core on a single-node K3s host with a SocketCAN
adapter on `can0` (RV-C, 250 kbit/s).

## Bootstrap

1. **Host CAN setup** (once): `sudo ./host/setup-can0.sh`, then `candump can0`.
2. **Enable GitHub Pages**: create an empty `gh-pages` branch, then in repo
   Settings → Pages set the source to `gh-pages` / root.
3. **Push to `main`** — `.github/workflows/release-chart.yaml` lints and publishes the chart
   to `https://ha.buzzuti.com`.
4. **Deploy**: `sudo cp gitops/k3s-helm-release.yaml /var/lib/rancher/k3s/server/manifests/rv-home-assistant.yaml`
5. **Connect HA to MQTT** (once, in the UI): Settings → Devices & Services → Add
   Integration → MQTT → broker `rv-home-assistant-mosquitto.rv-lab.svc.cluster.local`, port `1883`.

Releasing a change: bump `version` in `charts/rv-home-assistant/Chart.yaml`, push, then
bump `spec.version` in the HelmChart manifest on the node.
