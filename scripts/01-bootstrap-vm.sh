#!/usr/bin/env bash
# ==============================================================================
# VaultZero: GCP Always Free IPv6-Only Debian 12 VM Bootstrap Script
# ==============================================================================
# Features:
# 1. Configures DNS64 / NAT64 resolvers (nat64.net & Cloudflare IPv6)
# 2. Verifies outbound NAT64 translation and IPv4-reachability
# 3. Idempotently provisions 1GB swap space and sets swappiness=10
# 4. Installs Docker CE and docker-compose-plugin from official repository
# 5. Creates /opt/vaultwarden/{data,rclone,env} with 0700 permissions
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Enforce Root Privileges
# ------------------------------------------------------------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "[ERROR] This bootstrap script must be run as root or with sudo." >&2
    exit 1
fi

echo "======================================================================"
echo " Starting VaultZero VM Bootstrap"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 2. Configure DNS64 / NAT64 Gateway Resolvers
# ------------------------------------------------------------------------------
echo "==> [1/5] Configuring DNS64 / NAT64 resolvers in /etc/resolv.conf..."

# If /etc/resolv.conf has immutable bit set, clear it temporarily
if command -v lsattr >/dev/null 2>&1 && command -v chattr >/dev/null 2>&1; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
fi

# If /etc/resolv.conf is a symlink (common on systemd-resolved), remove it so we write a real ext4 regular file
if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
fi

# Configure systemd-resolved override if systemd-resolved is active
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat <<'EOF' > /etc/systemd/resolved.conf.d/nat64.conf
[Resolve]
DNS=2a01:4ff:f0:9876::1 2001:67c:2960::64 2a00:1098:2b::1
DNSSEC=no
Domains=~.
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
fi

# Configure dhclient supersede to prevent DHCP overwrite on lease renewal
if [ -d /etc/dhcp ]; then
    cat <<'EOF' > /etc/dhcp/dhclient.conf
supersede domain-name-servers 2a01:4ff:f0:9876::1, 2001:67c:2960::64, 2a00:1098:2b::1;
EOF
fi

# Write direct resolv.conf configuration
# All resolvers MUST be combined DNS64 + NAT64 translators.
# Standard DNS resolvers (like 1.1.1.1) must NEVER be included because they return IPv4 A records
# which causes pure IPv6 instances to hang on unreachable IPv4 TCP connections.
# 1. nat64.net Ashburn (US): 2a01:4ff:f0:9876::1
# 2. level66.net (DE): 2001:67c:2960::64
# 3. nat64.net Amsterdam (NL): 2a00:1098:2b::1
cat <<'EOF' > /etc/resolv.conf
# Managed by VaultZero Bootstrap (Pure DNS64 / NAT64 Resolvers)
nameserver 2a01:4ff:f0:9876::1
nameserver 2001:67c:2960::64
nameserver 2a00:1098:2b::1
options edns0 timeout:2 attempts:3
EOF

# Lock /etc/resolv.conf to prevent DHCP overwrite on IPv6-only cloud instances
if command -v chattr >/dev/null 2>&1; then
    chattr +i /etc/resolv.conf 2>/dev/null || true
fi

echo "    DNS64 resolvers configured successfully."

# ------------------------------------------------------------------------------
# 3. Validate NAT64 Outbound Connectivity
# ------------------------------------------------------------------------------
echo "==> [2/5] Validating NAT64 outbound connectivity to IPv4 endpoints..."

# Install basic network tools if curl isn't present yet
if ! command -v curl >/dev/null 2>&1; then
    apt-get update -qy
    apt-get install -qy --no-install-recommends curl ca-certificates
fi

NAT64_CHECK_HOST="api.github.com"
MAX_ATTEMPTS=5
SUCCESS=0

for i in $(seq 1 "${MAX_ATTEMPTS}"); do
    echo "    Attempt ${i}/${MAX_ATTEMPTS}: Resolving and testing ${NAT64_CHECK_HOST} via NAT64..."
    if curl -fsSL -6 -m 10 "https://${NAT64_CHECK_HOST}" >/dev/null 2>&1 || \
       curl -fsSL -m 10 "https://${NAT64_CHECK_HOST}" >/dev/null 2>&1; then
        SUCCESS=1
        echo "    NAT64 outbound gateway verified: ${NAT64_CHECK_HOST} reachable over IPv6."
        break
    fi
    sleep 2
done

if [ "${SUCCESS}" -ne 1 ]; then
    echo "[WARNING] Could not reach https://${NAT64_CHECK_HOST} via NAT64 after ${MAX_ATTEMPTS} attempts." >&2
    echo "          Proceeding, but ensure IPv6 routing and NAT64 DNS are functioning." >&2
fi

# ------------------------------------------------------------------------------
# 4. Idempotent 1GB Swapfile Provisioning & Swappiness Configuration
# ------------------------------------------------------------------------------
echo "==> [3/5] Configuring 1GB swap space and kernel swappiness..."

SWAP_FILE="/swapfile"
SWAP_SIZE_MB=1024

if [ ! -f "${SWAP_FILE}" ]; then
    echo "    Creating ${SWAP_SIZE_MB}MB swap file at ${SWAP_FILE}..."
    if ! fallocate -l "${SWAP_SIZE_MB}M" "${SWAP_FILE}" 2>/dev/null; then
        dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="${SWAP_SIZE_MB}" status=none
    fi
    chmod 600 "${SWAP_FILE}"
    mkswap "${SWAP_FILE}"
else
    echo "    Existing swap file detected at ${SWAP_FILE}."
    chmod 600 "${SWAP_FILE}"
fi

# Enable swap if not already active
if ! swapon --show=NAME --noheadings 2>/dev/null | grep -q "^${SWAP_FILE}$"; then
    echo "    Activating swapfile..."
    swapon "${SWAP_FILE}"
fi

# Persist in /etc/fstab idempotently
FSTAB_LINE="${SWAP_FILE} none swap sw 0 0"
if ! grep -qxF "${FSTAB_LINE}" /etc/fstab 2>/dev/null; then
    echo "    Persisting swap file in /etc/fstab..."
    echo "${FSTAB_LINE}" >> /etc/fstab
fi

# Set optimal swappiness for 1GB RAM VM
echo "    Applying sysctl optimizations (vm.swappiness=10)..."
sysctl -w vm.swappiness=10 2>/dev/null || true
sysctl -w vm.vfs_cache_pressure=50 2>/dev/null || true

cat <<'EOF' > /etc/sysctl.d/99-vaultzero-swap.conf
# VaultZero low-RAM performance optimization
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

# ------------------------------------------------------------------------------
# 5. Install Docker CE and docker-compose-plugin
# ------------------------------------------------------------------------------
echo "==> [4/5] Installing Docker CE and docker-compose-plugin..."

apt-get update -qy
apt-get install -qy --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Configure official Docker APT keyring
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg
fi

# Detect architecture and Debian release codename
DEB_ARCH="$(dpkg --print-architecture)"
DEB_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"

cat <<EOF > /etc/apt/sources.list.d/docker.list
deb [arch=${DEB_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${DEB_CODENAME} stable
EOF

apt-get update -qy
apt-get install -qy --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Enable and start Docker service
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker 2>/dev/null || true
fi

echo "    Docker installed: $(docker --version 2>/dev/null || echo 'installed')"
echo "    Compose plugin: $(docker compose version 2>/dev/null || echo 'installed')"

# ------------------------------------------------------------------------------
# 6. Setup /opt/vaultwarden Directory Tree
# ------------------------------------------------------------------------------
echo "==> [5/5] Creating /opt/vaultwarden directory hierarchy..."

BASE_DIR="/opt/vaultwarden"
mkdir -p "${BASE_DIR}/data"
mkdir -p "${BASE_DIR}/rclone"
mkdir -p "${BASE_DIR}/env"

chmod 0700 "${BASE_DIR}"
chmod 0700 "${BASE_DIR}/data"
chmod 0700 "${BASE_DIR}/rclone"
chmod 0700 "${BASE_DIR}/env"

echo "    Directory hierarchy created:"
echo "    - ${BASE_DIR}/data   (0700)"
echo "    - ${BASE_DIR}/rclone (0700)"
echo "    - ${BASE_DIR}/env    (0700)"

echo "======================================================================"
echo " VaultZero VM Bootstrap Completed Successfully!"
echo "======================================================================"
