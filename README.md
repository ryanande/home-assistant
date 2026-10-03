# home-assistant — RV-C lab on K3s

Umbrella Helm chart (`charts/rv-home-assistant`) deploying Mosquitto, Home Assistant Core
and [LibreCoach](https://librecoach.com) (RV-C decoding) on a single-node K3s host with a
SocketCAN adapter on `can0` (RV-C, 250 kbit/s). Deployed by Argo CD straight from `main`.

```
gitops/argocd/argocd-install.yaml      K3s HelmChart that installs Argo CD
gitops/argocd/root-app.yaml            app-of-apps root, applied once
gitops/argocd/apps/*.yaml              one Application per app, synced from git
gitops/k3s-helm-release.yaml           legacy alternative (K3s Helm controller only)
```

## Hardware

GMKtec NucBox K8 Plus (Ryzen 7 8845HS, DDR5, 1 TB NVMe, 2× Intel I226-V 2.5 GbE) +
DSD TECH SH-C31G USB-CAN adapter (candleLight / `gs_usb`). Everything needed is in
Ubuntu 24.04's stock kernel; no extra drivers.

## Fresh install

**1. BIOS** (press `Del` or `Esc` at power-on)
- **Auto Power On after AC loss: enabled.** The PC comes back by itself whenever coach power is restored.
- **Power mode: Silent (35 W) or Balanced (54 W).** This stack idles at a few percent CPU; save the battery.

**2. Ubuntu Server 24.04 LTS** (USB installer from ubuntu.com)
- Wired Ethernet on either port; give it a DHCP reservation on your router.
- Storage: *Use an entire disk* with the default LVM layout. The installer only gives `/`
  100 GiB; the bootstrap script grows it to the whole disk.
- Tick **Install OpenSSH server**. Skip the featured snaps (no Docker or MicroK8s).

**3. Bootstrap** (over SSH, with the CAN adapter plugged in if you have it)

```bash
git clone https://github.com/ryanande/home-assistant.git
cd home-assistant
sudo ./bootstrap.sh
```

It takes about 10 minutes and is safe to re-run. It installs the host CAN config, K3s
and Argo CD, then Argo CD deploys Mosquitto, the CAN bridge and Home Assistant from
this repo. At the end it prints the URLs, the Argo CD `admin` password and the CAN
status. `./bootstrap.sh --help` lists the settings (timezone, K3s version, ...).

**4. Finish in the browser**
- Home Assistant `http://<mini-pc-ip>:8123`: create your account, then Settings → Devices &
  Services → Add Integration → MQTT → broker
  `rv-home-assistant-mosquitto.rv-lab.svc.cluster.local`, port `1883`.
- LibreCoach: in Home Assistant open your profile → Security → Long-lived access tokens →
  Create token, then on the mini PC run `./scripts/set-ha-token.sh` and paste it. The script
  stores it in a cluster Secret (never in git), restarts LibreCoach and checks it works.
- Argo CD `https://<mini-pc-ip>:8443` (self-signed certificate): change the `admin`
  password under User Info, then `kubectl -n argocd delete secret argocd-initial-admin-secret`.

**Troubleshooting**
- `can0` missing: plug in the adapter, then `sudo networkctl reconfigure can0` and `candump can0`.
- Ethernet link drops on the I226-V ports are a known issue with Energy Efficient
  Ethernet; `sudo ethtool --set-eee <iface> eee off` fixes it if you see it.

## LibreCoach without the Supervisor

LibreCoach ships as a Home Assistant OS add-on whose installer drives the HA Supervisor.
This chart runs LibreCoach's own code **unmodified** and supplies the few things it expects
from the add-on environment instead:

| LibreCoach expects | Provided by |
|---|---|
| broker at `core-mosquitto` | a Service alias for the chart's Mosquitto |
| `http://supervisor/core/...` (REST + websocket) | `supervisor` Service → nginx proxy to Home Assistant's API |
| `SUPERVISOR_TOKEN` | the `librecoach-ha-token` Secret (`scripts/set-ha-token.sh`) |
| `/data/options.json` | ConfigMap rendered from `librecoach.options` |
| retained `librecoach/config/*` toggles | an init container of the Node-RED pod |
| Node-RED add-on with the flows | Node-RED pod; flows copied from the pinned LibreCoach image |

`vehicle_bridge` (CAN ↔ MQTT) and the Node-RED flows (the RV-C decoder) both come from
`ghcr.io/backroads4me/amd64-librecoach:<librecoach.version>`, so they always match.

- **Upgrade LibreCoach**: bump `librecoach.version` in `gitops/argocd/apps/rv-home-assistant.yaml`.
  The CI test (`.github/workflows/test-stack.yaml`) runs on every change; check it before merging.
- **Node-RED editor**: not exposed. `kubectl -n rv-lab port-forward svc/rv-home-assistant-node-red 1880`,
  then http://localhost:1880. LibreCoach replaces the flows on every start (edits are backed up to
  `/config/librecoach-backups`); set `librecoach.nodeRed.preventFlowUpdates: true` to keep edits.
- **Victron Cerbo GX**: on the GX, Settings → Services → enable MQTT on LAN, and give it a DHCP
  reservation. Then set `librecoach.options.victron_enabled: true` and
  `librecoach.victron.gxAddress: <cerbo-ip>` (the flows look for `venus.local`, which pods can't resolve).
- **Not wired up yet**: Bluetooth devices (Micro-Air, Hughes) need Home Assistant Bluetooth access.

## Day-to-day

- **Change the deployment**: edit `charts/rv-home-assistant/` or the values in
  `gitops/argocd/apps/rv-home-assistant.yaml`, push to `main`. Argo CD syncs within ~2 minutes;
  manual changes made with `kubectl` are reverted (self-heal).
- **Add an app**: commit a new Application manifest under `gitops/argocd/apps/`.
- **Upgrade Argo CD**: bump `version` in `gitops/argocd/argocd-install.yaml`, copy it to the node again.

`.github/workflows/release-chart.yaml` still lints every chart change and publishes chart
releases to `https://ha.buzzuti.com` for the legacy path; Argo CD does not need them.
