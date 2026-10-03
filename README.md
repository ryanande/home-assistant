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

## Fresh install

1. **Host CAN setup** (once): `sudo ./host/setup-can0.sh`, then `candump can0`.
2. **Install Argo CD**:
   `sudo cp gitops/argocd/argocd-install.yaml /var/lib/rancher/k3s/server/manifests/argocd.yaml`
   then wait for it: `kubectl -n argocd rollout status deploy/argocd-server`
3. **Bootstrap the apps** (once): `kubectl apply -f gitops/argocd/root-app.yaml`
4. **Log in** at `https://<mini-pc-ip>:8443` (self-signed certificate) as `admin`. Password:
   `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`
   Change it under User Info, then `kubectl -n argocd delete secret argocd-initial-admin-secret`.
5. **Connect HA to MQTT** (once, in the HA UI): Settings → Devices & Services → Add
   Integration → MQTT → broker `rv-home-assistant-mosquitto.rv-lab.svc.cluster.local`, port `1883`.

Home Assistant is at `http://<mini-pc-ip>:8123`.

## Switching over from the K3s HelmChart

Only needed if `rv-home-assistant` was already installed with `gitops/k3s-helm-release.yaml`.
Both data volumes survive; the pods are down for a minute or two.

1. On the node, set `version: 0.2.0` in
   `/var/lib/rancher/k3s/server/manifests/rv-home-assistant.yaml` and wait for the upgrade
   (`kubectl -n kube-system get jobs` shows `helm-install-rv-home-assistant` complete).
   0.2.0 marks the Mosquitto volume as kept on uninstall; the HA volume already was.
2. Remove the old release. K3s does not delete anything when a manifest file is removed,
   so both commands are needed:
   ```
   sudo rm /var/lib/rancher/k3s/server/manifests/rv-home-assistant.yaml
   kubectl -n kube-system delete helmchart rv-home-assistant
   kubectl -n rv-lab get pvc     # both PVCs must still be listed
   ```
3. Follow **Fresh install** from step 2. Argo CD uses the same release name, so it
   recreates the workloads with identical names and picks up the existing volumes.

## Day-to-day

- **Change the deployment**: edit `charts/rv-home-assistant/` or the values in
  `gitops/argocd/apps/rv-home-assistant.yaml`, push to `main`. Argo CD syncs within ~2 minutes;
  manual changes made with `kubectl` are reverted (self-heal).
- **Add an app**: commit a new Application manifest under `gitops/argocd/apps/`.
- **Upgrade Argo CD**: bump `version` in `gitops/argocd/argocd-install.yaml`, copy it to the node again.

`.github/workflows/release-chart.yaml` still lints every chart change and publishes chart
releases to `https://ha.buzzuti.com` for the legacy path; Argo CD does not need them.
