# VaultZero

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GCP Always Free](https://img.shields.io/badge/GCP-Always%20Free%20$0.00-success.svg)](https://cloud.google.com/free)
[![Cloudflare Tunnel](https://img.shields.io/badge/Cloudflare-Zero%20Trust%20Tunnel-orange.svg)](https://www.cloudflare.com/products/tunnel/)
[![Pure IPv6](https://img.shields.io/badge/Network-Pure%20IPv6%20Native-blueviolet.svg)](#)
[![Docker Host Mode](https://img.shields.io/badge/Docker-Host%20Networking-2496ed.svg)](#)

**Turnkey, production-grade, $0.00/month self-hosted Vaultwarden on Google Cloud Platform Always Free with Cloudflare Tunnel, Zero Trust WAF, and automated Cloudflare R2 disaster recovery.**

</div>

---

## The Problem: The GCP "Always Free" Fee Trap

Google Cloud Platform offers a generous Always Free tier including one `e2-micro` instance, 30 GB standard persistent disk, and 1 GB outbound internet traffic per month in US regions (`us-west1`, `us-central1`, `us-east1`).

However, unsuspecting developers attempting to host Bitwarden / Vaultwarden routinely hit unexpected charges:

1. **IPv4 Address Surcharge**: GCP charges **$0.005/hour (~$3.65 – $3.72/month)** for in-use external IPv4 addresses. Running an instance with standard IPv4 invalidates the "$0 promise".
2. **NAT Gateway Costs**: Disabling public IPv4 and using GCP Cloud NAT incurs hourly gateway charges plus data processing fees.
3. **Public Port Exposure & Attack Surface**: Exposing ports 80/443 directly to the public internet requires Certbot management, leaves servers vulnerable to automated bot scans, and risks brute-force credential stuffing.
4. **Reverse Proxy Lockout Glitch**: Misconfigured proxies without `CF-Connecting-IP` report all client connections as `127.0.0.1`. A single user typing incorrect credentials can trigger Vaultwarden's rate limiter and lock out all users globally.

---

## The VaultZero Solution

VaultZero is engineered from the ground up to achieve **genuine $0.00/month operation**, invisible attack surface, and rock-solid reliability:

- **Pure External IPv6 Native ($0.00/month)**: Provisioned with `--no-address` (no external IPv4), allocating a free external `/96` IPv6 subnet on GCP Premium Tier.
- **Dual-Stack Internal VPC (`IPV4_IPV6`)**: Retains internal-only private IPv4 routing for GCP Identity-Aware Proxy (IAP), allowing admin SSH via `35.235.240.0/20` with zero open firewall ports.
- **Cloudflare Tunnel (`cloudflared`) over Pure IPv6**: The host establishes an outbound QUIC tunnel directly to Cloudflare edge nodes using `edge-ip-version: 6`. No incoming ports (80/443) are ever opened in the GCP firewall.
- **Universal IPv4/IPv6 Client Access**: Cloudflare Edge terminates incoming HTTPS traffic, issues free managed SSL/TLS certificates, and routes traffic from any client (IPv4 or IPv6) through the encrypted tunnel.
- **NAT64 / DNS64 Routing Gateway**: Configured with `nat64.net` dual-homed translation servers to allow pure-IPv6 VMs to pull updates and packages from IPv4-only repositories seamlessly.
- **Docker Host Networking (`network_mode: "host"`)**: Bypasses Docker's virtual bridge IPv4 routing deadlocks on pure IPv6 hosts, ensuring containers share host IPv6 and NAT64 routes directly.
- **Real Client IP Preservation**: Enforces `IP_HEADER=CF-Connecting-IP` in Vaultwarden so fail2ban and audit logs accurately identify remote clients instead of masking them behind `127.0.0.1`.
- **Zero-Lock Hot Backups to Cloudflare R2**: Accompanied by `ttionya/vaultwarden-backup` performing SQLite zero-lock hot backups with AES-256 encryption, uploaded to Cloudflare R2 (10 GB free storage, $0 egress fees) with 30-day retention.

---

## Architecture Overview

```mermaid
flowchart TD
    subgraph Clients["Any Network Client (IPv4 / IPv6)"]
        Browser["Browser Extension (Chrome / Edge / Firefox)"]
        Mobile["Bitwarden Mobile App (iOS / Android)"]
        WebVault["Bitwarden Web Vault"]
    end

    subgraph CF["Cloudflare Global Edge"]
        CF_Edge["Cloudflare Edge Anycast (Free SSL/TLS)"]
        CF_WAF["Cloudflare WAF (Rate Limiting on /identity/connect/token)"]
        CF_Access["Cloudflare Zero Trust Access (/admin OTP Verification)"]
        CF_Tunnel_Edge["Cloudflare Tunnel Edge Endpoint (IPv6)"]
        R2["Cloudflare R2 Object Storage (10 GB Free / $0 Egress)"]
    end

    subgraph GCP["Google Cloud Platform (us-west1 Free Tier)"]
        subgraph VPC["VPC Network (Dual-Stack IPV4_IPV6)"]
            IAP_GW["GCP IAP Proxy (35.235.240.0/20)\nInternal IPv4 SSH Management"]
            
            subgraph VM["Compute Engine VM (e2-micro / Debian 12)"]
                NAT64["DNS64/NAT64 Translator (nat64.net)"]
                TunnelClient["cloudflared Systemd Service (edge-ip-version: 6)"]
                
                subgraph DockerHost["Docker Compose (Host Network Mode)"]
                    Vaultwarden["Vaultwarden Container (127.0.0.1:8080 / CF-Connecting-IP)"]
                    BackupService["ttionya/vaultwarden-backup Container (AES Encrypted Hot Backup)"]
                end
            end
        end
        FW["GCP VPC Firewall (Inbound: 0 Open Ports / Ingress via IAP Only)"]
    end

    Clients -->|"HTTPS (Port 443) vault.yourdomain.com"| CF_Edge
    CF_Edge --> CF_WAF
    CF_Edge --> CF_Access
    CF_WAF --> CF_Tunnel_Edge
    CF_Access --> CF_Tunnel_Edge

    TunnelClient ==>|"Outbound Pure IPv6 QUIC Tunnel (edge-ip-version: 6)"| CF_Tunnel_Edge
    TunnelClient -->|"HTTP Ingress (127.0.0.1:8080)"| Vaultwarden
    BackupService -->|"Encrypted Backup Sync via Rclone"| R2
    IAP_GW -.->|"Internal SSH"| VM
```

---

## Step-by-Step Deployment Guides

For detailed, production-grade deployment instructions, follow our comprehensive runbooks:

- 📖 **[GCP Always Free VM Deployment Guide](docs/gcp-deployment.md)**: Exact copy-pasteable `gcloud` CLI commands and GCP Web Console instructions to provision an `e2-micro` VM with dual-stack VPC (`IPV4_IPV6`), no public IPv4 (`--no-address`), and strict IAP firewall rules (`35.235.240.0/20`).
- 🛡️ **[Cloudflare Zero Trust, WAF & R2 Configuration Guide](docs/cloudflare-setup.md)**: Cloudflare Tunnel setup, public hostname routing (`127.0.0.1:8080`), WAF login rate limiting (`/identity/connect/token`), Zero Trust Access email OTP protection for `/admin`, and R2 encrypted backup configuration.

---

## 3-Step Quickstart

### Step 1: Provision GCP Always Free Instance

Follow the [GCP Deployment Guide](docs/gcp-deployment.md) to provision an `e2-micro` VM with dual-stack VPC (`IPV4_IPV6`), no external IPv4 (`--no-address`), a free `/96` external IPv6 subnet, 30 GB standard persistent disk, and firewall rules restricted to GCP IAP (`35.235.240.0/20`).

Connect to your instance securely via Google Cloud IAP SSH:

```bash
gcloud compute ssh vaultwarden-free --tunnel-through-iap --zone us-west1-b
```

### Step 2: Bootstrap VM & Cloudflare Tunnel

On the VM, clone this repository and run the automated host bootstrap:

```bash
sudo -i
git clone https://github.com/fewk/VaultZero.git /opt/vaultzero
cd /opt/vaultzero

# Bootstrap DNS64/NAT64 resolvers, 1GB swap, Docker CE, and directory hierarchy
bash scripts/01-bootstrap-vm.sh

# Follow docs/cloudflare-setup.md to create your tunnel, then install cloudflared:
bash scripts/02-setup-cloudflared.sh YOUR_CLOUDFLARE_TUNNEL_TOKEN
```

Configure your secrets and R2 backup credentials:

```bash
# Configure environment variables
cp .env.example .env
nano .env

# Configure Cloudflare R2 credentials for automated backups
cp rclone/rclone.conf.example /opt/vaultwarden/rclone/rclone.conf
nano /opt/vaultwarden/rclone/rclone.conf
chmod 0600 /opt/vaultwarden/rclone/rclone.conf
```

### Step 3: Deploy Services & Verify

Start Vaultwarden and the automated backup companion daemon:

```bash
docker compose up -d

# Verify zero public IPv4, zero public listening ports, and health
bash scripts/verify-health.sh
```

Follow the [Cloudflare Setup Guide](docs/cloudflare-setup.md) to enable WAF rate limiting on `/identity/connect/token` and protect `/admin` with Zero Trust Email OTP.

Access your Vaultwarden instance securely at `https://vault.yourdomain.com`!

---

## Directory Hierarchy

```text
VaultZero/
├── .env.example              # Sample environment configuration template
├── .gitignore                # Git exclusions for secrets and runtime data
├── LICENSE                   # MIT License
├── README.md                 # Project architecture and operations guide
├── docker-compose.yml        # Docker Compose orchestration (Vaultwarden + Backup)
├── docs/                     # Architecture specifications and implementation runbooks
│   ├── cloudflare-setup.md   # Cloudflare Tunnel, WAF, Zero Trust & R2 runbook
│   ├── gcp-deployment.md     # GCP Always Free VM & dual-stack VPC runbook
│   └── superpowers/
│       ├── plans/            # Implementation plans
│       └── specs/            # Engineering specifications
├── rclone/                   # Rclone configuration templates for Cloudflare R2
│   └── rclone.conf.example
├── scripts/                  # Automated host lifecycle and operational scripts
│   ├── 01-bootstrap-vm.sh    # DNS64/NAT64, swap, Docker, and filesystem bootstrap
│   ├── 02-setup-cloudflared.sh # Cloudflare Tunnel IPv6 service installer
│   ├── 03-restore-backup.sh  # Zero-downtime disaster recovery & restore drill (< 3 min)
│   └── verify-health.sh      # Security invariant and architecture health auditor
├── systemd/                  # Systemd service configurations (cloudflared pure IPv6)
│   └── cloudflared.service
└── tests/                    # Automated test harness (pytest)
    ├── test_bootstrap_script.py
    ├── test_cloudflared_config.py
    ├── test_docker_compose.py
    ├── test_docs_links.py
    ├── test_repo_structure.py
    └── test_utility_scripts.py
```

---

## Security & Maintenance

- **Backups**: Backups run automatically every night, creating an AES-256 encrypted archive and syncing to Cloudflare R2.
- **Disaster Recovery Drill**: Run `bash scripts/03-restore-backup.sh --latest` to test restoring SQLite databases, attachments, and secrets in under 3 minutes.
- **Updates**: Run `docker compose pull && docker compose up -d` to upgrade Vaultwarden and backup containers with zero data loss.

---

## License

This project is licensed under the [MIT License](LICENSE).
