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
sudo bash <(curl -sL https://raw.githubusercontent.com/BorealTek/Treescout-Deployments/master/docker_deploy.sh)
```

**Local Dev (macOS/OrbStack):**
```bash
bash <(curl -sL https://raw.githubusercontent.com/BorealTek/Treescout-Deployments/master/orbstack_deploy.sh)
```

## 🚀 Manual Quick Start

1.  **Clone this repository** to your target machine (or local dev machine).
2.  **Configure**:
    ```bash
    cp deploy.conf.example deploy.conf
    nano deploy.conf
    ```
    *Edit the configuration with your domain, secrets, and repository URLs.*

3.  **Deploy**:

    **For Production (Ubuntu/Linux):**
    ```bash
    sudo ./docker_deploy.sh
    ```

    **For Local Dev (macOS/OrbStack):**
    ```bash
    ./orbstack_deploy.sh
    ```

## 📂 Structure

*   `docker_deploy.sh` - Main production deployment script.
*   `orbstack_deploy.sh` - Development deployment script (macOS optimized).
*   `deploy.conf` - **(Ignored)** Local configuration file containing secrets.
*   `deploy.conf.example` - Template configuration file.

## ⚠️ Notes

*   **Secrets**: never commit `deploy.conf` to version control.
*   **Requirements**: 
    *   Linux: Docker Engine, Docker Compose
    *   macOS: OrbStack (Recommended) or Docker Desktop
