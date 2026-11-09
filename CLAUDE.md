# CLAUDE.md

## Passport
- **Identity:** RV-C lab on the RV's single-node K3s: one umbrella Helm chart (`charts/rv-home-assistant`) deploying Mosquitto, Home Assistant Core and LibreCoach (RV-C CAN decoding), plus the host bootstrap that builds that node.
- **Owns:** the Home Assistant stack and its chart; `bootstrap.sh` (fresh install of K3s, Argo CD and host CAN config); `host/` CAN files (`can0`, 250 kbit/s); Argo CD install (`gitops/argocd/argocd-install.yaml`) and the app-of-apps root.
- **Does not own:** other services on the cluster (`notlost-k3s-containers`); workstation and node provisioning (`notlost-libre`, which overlaps on CAN/K3s host setup: unverified which is current).
- **Depends on / depended on by:** shares the cluster and Argo CD pattern with `notlost-k3s-containers`; external: LibreCoach image `ghcr.io/backroads4me/amd64-librecoach`, DSD TECH candleLight CAN adapter, optional Victron Cerbo GX.
- **Deploys to / runs on:** K3s on a GMKtec NucBox K8 Plus (Ubuntu 24.04/26.04), synced by Argo CD from `main` (self-heal: manual `kubectl` edits are reverted).
- **Entry points:** `README.md`; `bootstrap.sh`; `gitops/argocd/apps/rv-home-assistant.yaml` (values, `librecoach.version`); `charts/rv-home-assistant/`; `.github/workflows/test-stack.yaml`.
- **Hard rules:** change the deployment by pushing to `main`, not by `kubectl`; secrets (HA token) live in cluster Secrets via `scripts/set-ha-token.sh`, never in git; LibreCoach runs unmodified, the chart supplies its Supervisor expectations; bump `librecoach.version` only after CI passes.
- **Docs:** `README.md` (install, LibreCoach without Supervisor, day-to-day).
