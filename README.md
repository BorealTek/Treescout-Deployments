---
doc_type: how-to
owner: "@devops-team"
reviewers:
    - "@platform-team"
last_reviewed: 2026-03-23
review_cycle_days: 45
source_paths:
    - deployment/
stability: active
---

# BorealTek Treescout Deployer

Enterprise-grade deployment utilities for the FreeScout Helpdesk application.

## 🌲 Features

*   **Docker Enterprise Deployer**: Production-ready script for Ubuntu/Debian servers.
*   **OrbStack/macOS Deployer**: Local development setup with Cloudflare Tunnel support.
*   **Module Management**: Automated fetching and installation of FreeScout modules from Git.
*   **Zero-Downtime Updates**: Integrated update scripts.
*   **Secure by Default**: Generates SSL certs and handles secrets securely.

## ⚡ One-Line Install

You can run the installers directly without cloning the repository manually. The script will generate a configuration file for you.

**Production (Ubuntu/Linux):**
```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/BorealTek/Treescout-Deployments/master/docker/docker_deploy.sh)
```

**Local Dev (macOS/OrbStack):**
```bash
bash <(curl -sL https://raw.githubusercontent.com/BorealTek/Treescout-Deployments/master/orbstack/orbstack_deploy.sh)
```

## 🚀 Manual Quick Start

1.  **Clone this repository** to your target machine (or local dev machine).
2.  **Configure**:
    ```bash
    cp linux/deploy.conf.example linux/deploy.conf
    nano linux/deploy.conf
    ```
    *Edit the configuration with your domain, secrets, and repository URLs.*

3.  **Deploy**:

    **For Production (Ubuntu/Linux):**
    ```bash
    sudo ./docker/docker_deploy.sh
    ```

    **For Local Dev (macOS/OrbStack):**
    ```bash
    ./orbstack/orbstack_deploy.sh
    ```

## 📂 Structure

*   `docker/` - Docker-focused deploy scripts and sidecars (`docker_deploy.sh`, `cloudflared/`, `kroki/`).
*   `orbstack/` - OrbStack/macOS deploy script (`orbstack_deploy.sh`).
*   `gcp/` - GCP deploy tooling, bootstrap scripts, and guide.
*   `linux/` - Shared Linux deployment configuration and module manifest.

## ⚠️ Notes

*   **Secrets**: never commit `linux/deploy.conf` to version control.
*   **Requirements**:
    *   Linux: Docker Engine, Docker Compose
    *   macOS: OrbStack (Recommended) or Docker Desktop

---

## 🔐 SSH & Cloudflare Tunnel

The Cloudflare tunnel runs as a **separate, standalone stack** in [`docker/cloudflared/`](docker/cloudflared/) — intentionally decoupled from the app so that taking the app down for maintenance never kills SSH access, and so the tunnel can serve other hostnames/services on the same server.

See **[docker/cloudflared/README.md](docker/cloudflared/README.md)** for full setup instructions (Docker Compose, Zero Trust configuration, client `~/.ssh/config`, VS Code Remote SSH, and a systemd alternative).

