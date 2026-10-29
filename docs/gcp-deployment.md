# GCP Always Free VM Deployment Guide

This guide provides end-to-end, copy-pasteable instructions for provisioning an **Always Free** Google Cloud Platform (GCP) Compute Engine instance running pure IPv6 with Identity-Aware Proxy (IAP) management.

Following this guide guarantees **$0.00/month** cloud hosting cost while eliminating public IPv4 exposure.

---

## 1. Prerequisites & Always Free Constraints

Google Cloud's **Always Free Tier** grants eligible accounts:
- **1 non-preemptible `e2-micro` VM** per month in supported US regions:
  - `us-west1` (Oregon) - *Recommended*
  - `us-central1` (Iowa)
  - `us-east1` (South Carolina)
- **30 GB Standard Persistent Disk (`pd-standard`)** per month.
- **1 GB network egress** per month from North America to all region destinations (excluding China and Australia).

> [!WARNING]
> **The IPv4 Charge Trap**: Google Cloud charges **$0.005/hour (~$3.65 – $3.72/month)** for in-use external IPv4 addresses.
> You **MUST** specify `--no-address` when creating the instance.
> External IPv6 addresses on GCP are **100% free ($0.00)**.

---

## 2. Configuration Variables

Define your deployment parameters in your local shell or GCP Cloud Shell:

```bash
export PROJECT_ID="your-gcp-project-id"
export REGION="us-west1"
export ZONE="us-west1-b"
export VPC_NAME="vaultzero-vpc"
export SUBNET_NAME="vaultzero-subnet-us-west1"
export INSTANCE_NAME="vaultwarden-free"
```

---

## 3. Method A: Command-Line (`gcloud` CLI) Deployment

Run these commands using the Google Cloud SDK (`gcloud`) or within [Google Cloud Shell](https://shell.cloud.google.com).

### Step 3.1: Configure Active Project & Enable APIs

```bash
# Set your active GCP project
gcloud config set project "${PROJECT_ID}"

# Enable Compute Engine API
gcloud services enable compute.googleapis.com
```

### Step 3.2: Create Dual-Stack VPC Network

A dual-stack VPC provides private internal IPv4 (required for GCP IAP tunnel routing) alongside public IPv6.

```bash
gcloud compute networks create "${VPC_NAME}" \
    --subnet-mode=custom \
    --bgp-routing-mode=regional
```

### Step 3.3: Create Dual-Stack Subnet

Assign a private IPv4 CIDR (`10.0.0.0/24`) and enable external IPv6 allocation (`/96` per VM assigned automatically from GCP's `/64` block):

```bash
gcloud compute networks subnets create "${SUBNET_NAME}" \
    --network="${VPC_NAME}" \
    --region="${REGION}" \
    --range="10.0.0.0/24" \
    --stack-type=IPV4_IPV6 \
    --ipv6-access-type=EXTERNAL
```

### Step 3.4: Create Strict IAP SSH Firewall Rule

Google Cloud Identity-Aware Proxy (IAP) forwards SSH traffic over an authenticated Google internal tunnel from CIDR `35.235.240.0/20`.

```bash
gcloud compute firewall-rules create "${VPC_NAME}-allow-iap-ssh" \
    --network="${VPC_NAME}" \
    --direction=INGRESS \
    --priority=1000 \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges="35.235.240.0/20" \
    --target-tags=vaultzero-node \
    --description="Allow SSH exclusively via Google Cloud IAP tunnel"
```

> [!NOTE]
> Do NOT create any firewall rules opening port 80 or 443 to `0.0.0.0/0` or `::/0`.
> Ingress traffic is handled securely via Cloudflare Tunnel outbound connections.

### Step 3.5: Provision the `e2-micro` Compute Engine Instance

Create the VM with:
- Machine type: `e2-micro`
- Disk: 30GB `pd-standard` (Debian 12)
- Network: Dual-stack (`IPV4_IPV6`)
- External IPv4: **NONE (`--no-address`)**
- Tags: `vaultzero-node`

```bash
gcloud compute instances create "${INSTANCE_NAME}" \
    --zone="${ZONE}" \
    --machine-type=e2-micro \
    --network-interface="network=${VPC_NAME},subnet=${SUBNET_NAME},stack-type=IPV4_IPV6,no-address" \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --boot-disk-size=30GB \
    --boot-disk-type=pd-standard \
    --boot-disk-auto-delete \
    --tags=vaultzero-node \
    --metadata=enable-oslogin=TRUE
```

### Step 3.6: Verify Zero-Cost Network Configuration

Verify that the instance has an external IPv6 address and **no external IPv4 address**:

```bash
gcloud compute instances describe "${INSTANCE_NAME}" \
    --zone="${ZONE}" \
    --format="yaml(name,networkInterfaces[0].networkIP,networkInterfaces[0].ipv6Address,networkInterfaces[0].accessConfigs)"
```

Expected output:
```yaml
name: vaultwarden-free
networkInterfaces:
- ipv6Address: 2600:1900:...
  networkIP: 10.0.0.2
```
Confirm that `accessConfigs` (external IPv4) is `null` or omitted entirely.

### Step 3.7: Connect via IAP SSH Tunnel

Connect to the instance using the encrypted IAP proxy:

```bash
gcloud compute ssh "${INSTANCE_NAME}" \
    --zone="${ZONE}" \
    --tunnel-through-iap
```

---

## 4. Method B: GCP Cloud Console (Web UI) Walkthrough

If you prefer configuring via the GCP Web Console:

### Step 4.1: Create VPC Network & Subnet
1. Open [VPC networks](https://console.cloud.google.com/networking/networks/list).
2. Click **Create VPC Network**.
3. **Name**: `vaultzero-vpc`.
4. Under **Subnets** -> **Subnet creation mode**, choose **Custom**.
5. Add a subnet:
   - **Name**: `vaultzero-subnet-us-west1`
   - **Region**: `us-west1`
   - **Stack type**: Select **Dual-stack (IPv4 and IPv6)**
   - **IPv4 range**: `10.0.0.0/24`
   - **IPv6 access type**: Select **External**
6. Click **Create**.

### Step 4.2: Create IAP Firewall Rule
1. Open [Firewall policies](https://console.cloud.google.com/net-security/firewall-manager/firewall-policies/list).
2. Click **Create Firewall Rule**:
   - **Name**: `vaultzero-allow-iap-ssh`
   - **Network**: `vaultzero-vpc`
   - **Direction of traffic**: `Ingress`
   - **Action on match**: `Allow`
   - **Targets**: `Specified target tags` -> enter tag `vaultzero-node`
   - **Source filter**: `IPv4 ranges` -> enter `35.235.240.0/20`
   - **Protocols and ports**: Specified protocols and ports -> check `TCP` -> enter `22`
3. Click **Create**.

### Step 4.3: Create Compute Engine VM
1. Open [VM instances](https://console.cloud.google.com/compute/instances).
2. Click **Create Instance**:
   - **Name**: `vaultwarden-free`
   - **Region**: `us-west1 (Oregon)`
   - **Zone**: `us-west1-b` (or `us-west1-a` / `us-west1-c`)
   - **Machine configuration**: Series `E2`, Machine type `e2-micro` (2 vCPU, 1 GB memory)
   - **Boot disk**: Click **Change** -> OS: `Debian`, Version: `Debian GNU/Linux 12 (bookworm)`, Boot disk type: `Standard persistent disk`, Size: `30 GB`. Click **Select**.
   - Expand **Advanced options** -> **Networking**:
     - Under **Network tags**, add `vaultzero-node`
     - Under **Network interfaces**, click `default` to edit:
       - **Network**: `vaultzero-vpc`
       - **Subnetwork**: `vaultzero-subnet-us-west1`
       - **IP stack type**: Select **IPv4 and IPv6 (dual-stack)**
       - **Primary internal IPv4**: `Ephemeral (Custom)` or `Ephemeral (Automatic)`
       - **External IPv4 address**: Select **None** *(CRITICAL: Prevents IPv4 billing)*
       - **External IPv6 address**: Select **Auto-allocate an external IPv6 address (/96)**
     - Click **Done**.
3. Click **Create**.

---

## 5. Host Bootstrap & Initialization

Once logged into your VM via `gcloud compute ssh "${INSTANCE_NAME}" --zone="${ZONE}" --tunnel-through-iap`:

```bash
# Switch to root
sudo -i

# Set pure DNS64/NAT64 resolvers so pure-IPv6 VM can resolve and reach IPv4 endpoints (e.g. GitHub)
echo -e "nameserver 2a01:4ff:f0:9876::1\nnameserver 2001:67c:2960::64\nnameserver 2a00:1098:2b::1" > /etc/resolv.conf

# Clone the repository
git clone https://github.com/fewk/VaultZero.git /opt/vaultzero
cd /opt/vaultzero

# Run automated bootstrap (installs DNS64/NAT64, 1GB swap, Docker CE, and directory structure)
bash scripts/01-bootstrap-vm.sh
```

The bootstrap script will verify outbound pure IPv6 connectivity through NAT64 translators, install Docker CE, and prepare `/opt/vaultwarden`.

---

## 6. Next Steps

Proceed to [Cloudflare Zero Trust & Tunnel Setup](cloudflare-setup.md) to:
1. Establish the outbound encrypted tunnel.
2. Configure WAF brute-force rate limiting.
3. Protect the admin panel with Zero Trust Email OTP.
4. Set up automated Cloudflare R2 disaster recovery backups.
