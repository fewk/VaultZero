# Cloudflare Zero Trust, WAF & R2 Configuration Guide

This guide walks through configuring the Cloudflare edge security stack for VaultZero:
1. **Cloudflare Tunnel (`cloudflared`)** for pure IPv6 zero-inbound-port access.
2. **Public Hostname Routing** directing traffic to local port `8080`.
3. **Cloudflare WAF Rate Limiting** to prevent brute-force login attacks.
4. **Cloudflare Zero Trust Access Application** to protect `/admin` with Email OTP.
5. **Cloudflare R2 Object Storage** for encrypted zero-cost hot disaster recovery backups.

---

## 1. Cloudflare Tunnel Provisioning

Cloudflare Tunnel creates an encrypted, outbound-only tunnel between your GCP VM and Cloudflare's global edge network. No inbound firewall ports (such as 80 or 443) need to be open on your VM.

### Step 1.1: Create a Tunnel in Cloudflare Zero Trust Dashboard
1. Log in to the [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/).
2. Navigate to **Networks** -> **Tunnels** (or **Access** -> **Tunnels**).
3. Click **Add a tunnel** (or **Create a tunnel**).
4. Select **Cloudflared** as the connector type and click **Next**.
5. Name your tunnel: `vaultzero-tunnel` and click **Save tunnel**.

### Step 1.2: Retrieve Tunnel Token
Under the **Install and run a connector** step:
- Cloudflare displays installation commands for various environments.
- Locate the token string inside the command (the long base64 string starting with `ey...` following `--token`).
- Copy this token string for use on the VM.

### Step 1.3: Deploy `cloudflared` on the GCP VM
SSH into your GCP VM via IAP:

```bash
gcloud compute ssh vaultwarden-free --zone us-west1-b --tunnel-through-iap
```

Run the VaultZero cloudflared installer with your token:

```bash
sudo bash /opt/vaultzero/scripts/02-setup-cloudflared.sh <YOUR_CLOUDFLARE_TUNNEL_TOKEN>
```

This installer:
- Downloads and installs the official `cloudflared` package.
- Sets up `/etc/cloudflared/config.yml` with `edge-ip-version: "6"` to ensure outbound connectivity over pure IPv6.
- Installs and enables the `cloudflared` systemd service.

Verify tunnel status:
```bash
sudo systemctl status cloudflared
```

---

## 2. Public Hostname Routing (路由配置)

Route your custom domain directly through the tunnel to Vaultwarden's local container port.

1. In the Cloudflare Zero Trust Dashboard, go to your tunnel (`vaultzero-tunnel`) and select the **Public Hostnames** tab *(in Chinese dashboard, this tab is labeled **“路由”**)*.
2. Click **Add a public hostname** (添加公共主机名):
   - **Subdomain** (子域): `vault` (or your preferred subdomain like `pw`)
   - **Domain** (域): Select your domain from the dropdown (e.g. `yourdomain.com`)
   - **Path** (路径): Leave blank
   - **Service** (服务):
     - **Type** (类型): **`HTTP`** *(CRITICAL: Must be HTTP, NOT HTTPS! Cloudflare edge terminates SSL; local tunnel communication to Vaultwarden is plaintext HTTP)*
     - **URL**: `127.0.0.1:8080` (or `localhost:8080`)
3. Under **Additional application settings** -> **HTTP Settings**:
   - Ensure **HTTP Host Header** is left default or matches your domain.
4. Click **Save hostname** (保存主机名).

Cloudflare automatically manages and provisions universal SSL/TLS certificates for `vault.yourdomain.com`.

---

## 3. Cloudflare WAF Brute-Force Rate Limiting Rule

Vaultwarden authentication requests are sent to `/identity/connect/token`. We configure a strict rate limit at Cloudflare's edge to block credential stuffing attacks before requests ever reach your VM.

> [!CAUTION]
> **Do NOT use Managed Challenge for `/api/*` or the domain root!**
> Bitwarden mobile apps (iOS & Android) and browser extensions communicate via background API calls.
> If a Cloudflare **Managed Challenge** (CAPTCHA/Turnstile) is triggered, background sync fails immediately, causing mobile app synchronization errors and user lockouts.
> **Only use rate limiting with action "Block" (HTTP 429) targeting the specific login endpoint.**

### Configuration Steps:
1. Open the standard [Cloudflare Dashboard](https://dash.cloudflare.com/) and select your domain (`yourdomain.com`).
2. In the left navigation, go to **Security** -> **WAF** -> **Rate limiting rules**.
3. Click **Create rule**:
   - **Rule name**: `Vaultwarden Login Brute Force Protection`
   - **If incoming requests match... (Field expressions)**:
     - Field: `URI Path` -> Operator: `equals` -> Value: `/identity/connect/token`
     - Click **And**
     - Field: `Request Method` -> Operator: `equals` -> Value: `POST`
     - *Expression Preview*:
       ```text
       (http.request.uri.path eq "/identity/connect/token" and http.request.method eq "POST")
       ```
   - **Rate limit settings**:
     - **Requests**: `10`
     - **Period**: `1 minute` (or 60 seconds)
   - **Action**:
     - Choose **Block**
     - **Response type**: Default Cloudflare rate limiting error (HTTP 429)
     - **Duration**: `10 minutes` (or 1 minute)
4. Click **Deploy**.

---

## 4. Cloudflare Zero Trust Access Application for `/admin`

Vaultwarden has an administrative dashboard at `/admin`. To prevent unauthorized access or token bruteforcing, we place `/admin` behind Cloudflare Zero Trust Access with Email One-Time PIN (OTP) authentication.

### Configuration Steps:
1. In the [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/), go to **Access** -> **Applications**.
2. Click **Add an application** -> select **Self-hosted**.
3. **Application Configuration**:
   - **Application name**: `Vaultwarden Admin Portal`
   - **Session Duration**: `24 Hours`
   - **Application domain**:
     - Subdomain: `vault`
     - Domain: `yourdomain.com`
     - Path: `/admin*` (or `/admin`)
4. Click **Next**.
5. **Add Access Policy**:
   - **Policy name**: `Admin Email OTP Verification`
   - **Action**: `Allow`
   - **Configure rules**:
     - Selector: `Emails`
     - Value: Enter your trusted administrative email address (e.g. `admin@yourdomain.com`).
6. Click **Next** -> under **Authentication**, verify **One-time PIN** is enabled.
7. Click **Save application**.

Now, navigating to `https://vault.yourdomain.com/admin` prompts for an email verification code. Cloudflare validates the identity before forwarding any traffic to the server.

---

## 5. Cloudflare R2 Object Storage for Automated Backups

Cloudflare R2 provides S3-compatible object storage with **10 GB free storage per month** and **$0 egress fees**, making it the ideal target for `ttionya/vaultwarden-backup`.

### Step 5.1: Create R2 Bucket
1. In the standard Cloudflare Dashboard, navigate to **R2 Object Storage**.
2. Click **Create bucket**.
3. **Bucket name**: `vaultwarden-backup`.
4. **Location**: Automatic (or choose North America).
5. Click **Create Bucket**.

### Step 5.2: Create R2 API Credentials (S3 Compatible)
1. On the R2 home page, click **Manage R2 API Tokens** in the right sidebar.
2. Click **Create API token**:
   - **Token name**: `vaultwarden-backup-token`
   - **Permissions**: Select **Object Read & Write**
   - **Specify bucket(s)**: Select `vaultwarden-backup`
   - **TTL**: Forever (or as needed)
3. Click **Create API Token**.
4. Record the following credentials securely:
   - **Access Key ID**: `<CLOUDFLARE_R2_ACCESS_KEY_ID>`
   - **Secret Access Key**: `<CLOUDFLARE_R2_SECRET_ACCESS_KEY>`
   - **S3 Endpoint**: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`

### Step 5.3: Configure Rclone on the VM
Log into your VM and create the configuration file `/opt/vaultwarden/rclone/rclone.conf`:

```bash
sudo nano /opt/vaultwarden/rclone/rclone.conf
```

Insert the following configuration, substituting your credentials:

```ini
[r2]
type = s3
provider = Cloudflare
access_key_id = <CLOUDFLARE_R2_ACCESS_KEY_ID>
secret_access_key = <CLOUDFLARE_R2_SECRET_ACCESS_KEY>
endpoint = https://<ACCOUNT_ID>.r2.cloudflarestorage.com
acl = private
```

Secure the permissions:
```bash
sudo chmod 0600 /opt/vaultwarden/rclone/rclone.conf
sudo chown -R 0:0 /opt/vaultwarden/rclone
```

---

## 6. Launch & Health Verification

### Step 6.1: Start Services
On the VM in `/opt/vaultzero` (or `/opt/vaultwarden`):

```bash
# Configure .env with your domain and secure backup password
cp .env.example .env
nano .env

# Start Vaultwarden and backup companion daemon
docker compose up -d
```

### Step 6.2: Run Health Auditor
Execute the automated health and security audit script:

```bash
sudo bash scripts/verify-health.sh
```

This verifies:
- Zero public IPv4 address assigned.
- Pure IPv6 and NAT64 gateway connectivity.
- No public ports (80/443) listening to the internet.
- Vaultwarden local endpoint health (`http://127.0.0.1:8080/alive`).
- Real client IP preservation via `CF-Connecting-IP`.
- Cloudflare Tunnel systemd daemon running.

### Step 6.3: Initial Account Registration & Lock-Down
1. Visit `https://vault.yourdomain.com` in your browser.
2. Create your primary administrative master password account.
3. Edit `.env` to disable new registrations:
   ```env
   SIGNUPS_ALLOWED=false
   ```
4. Restart the container:
   ```bash
   docker compose up -d
   ```
5. Verify in a private browser window that new registrations are now disabled.

---

## 7. Disaster Recovery Drill

To verify your backup and restore lifecycle at any time:

```bash
# Trigger an immediate hot backup
docker restart vaultwarden-backup
docker logs -f vaultwarden-backup

# Run automated restore drill
sudo bash scripts/03-restore-backup.sh --latest
```

The restore script downloads the latest encrypted snapshot from Cloudflare R2, tests archive integrity, creates a rollback safety snapshot, restores all data, and brings the service back online in under 3 minutes.
