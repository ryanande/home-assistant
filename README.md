# home-assistant — RV-C lab on K3s

Umbrella Helm chart (`charts/rv-home-assistant`) deploying Mosquitto, the LibreCoach
CAN→MQTT bridge and Home Assistant Core on a single-node K3s host with a SocketCAN
adapter on `can0` (RV-C, 250 kbit/s). Deployed by Argo CD straight from `main`.

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
- Argo CD `https://<mini-pc-ip>:8443` (self-signed certificate): change the `admin`
  password under User Info, then `kubectl -n argocd delete secret argocd-initial-admin-secret`.

**Troubleshooting**
- `can0` missing: plug in the adapter, then `sudo networkctl reconfigure can0` and `candump can0`.
- Ethernet link drops on the I226-V ports are a known issue with Energy Efficient
  Ethernet; `sudo ethtool --set-eee <iface> eee off` fixes it if you see it.

## Day-to-day

- **Change the deployment**: edit `charts/rv-home-assistant/` or the values in
  `gitops/argocd/apps/rv-home-assistant.yaml`, push to `main`. Argo CD syncs within ~2 minutes;
  manual changes made with `kubectl` are reverted (self-heal).
- **Add an app**: commit a new Application manifest under `gitops/argocd/apps/`.
- **Upgrade Argo CD**: bump `version` in `gitops/argocd/argocd-install.yaml`, copy it to the node again.

`.github/workflows/release-chart.yaml` still lints every chart change and publishes chart
releases to `https://ha.buzzuti.com` for the legacy path; Argo CD does not need them.
