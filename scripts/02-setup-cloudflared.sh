#!/usr/bin/env bash
# ==============================================================================
# VaultZero: Cloudflare Tunnel (cloudflared) Pure IPv6 Setup & Systemd Installer
# ==============================================================================
# Target OS: Debian 12 (bookworm) / Ubuntu
# Architecture: amd64 / arm64
# ==============================================================================

set -euo pipefail

# Accept tunnel token via positional argument $1 or TUNNEL_TOKEN environment variable
TUNNEL_TOKEN="${1:-${TUNNEL_TOKEN:-}}"

# 1. Enforce root privileges
if [ "${VAULTZERO_TEST_MODE:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This installer must be run as root or with sudo." >&2
    exit 1
fi

echo "==> [1/4] Detecting system architecture..."
RAW_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "${RAW_ARCH}" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        echo "[ERROR] Unsupported system architecture: ${RAW_ARCH}. VaultZero supports amd64 and arm64." >&2
        exit 1
        ;;
esac
echo "    Detected architecture: ${ARCH}"

# 2. Download and install official cloudflared package
echo "==> [2/4] Downloading and installing official cloudflared package (${ARCH})..."
DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
TMP_DEB="/tmp/cloudflared-linux-${ARCH}.deb"

if [ "${VAULTZERO_TEST_MODE:-0}" != "1" ]; then
    # Prefer curl if available, fallback to wget
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 "${DEB_URL}" -o "${TMP_DEB}"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "${DEB_URL}" -O "${TMP_DEB}"
    else
        echo "[ERROR] Neither curl nor wget is available to download cloudflared." >&2
        exit 1
    fi

    dpkg -i "${TMP_DEB}" || apt-get install -fy
    rm -f "${TMP_DEB}"
    echo "    cloudflared installed successfully: $(cloudflared --version 2>/dev/null || echo 'installed')"
else
    echo "    [TEST MODE] Skipping cloudflared package download and installation"
fi

# 3. Setup configuration directory and template
CONFIG_DIR="${TEST_CONFIG_DIR:-/etc/cloudflared}"
CONFIG_FILE="${CONFIG_DIR}/config.yml"
DEFAULT_FILE="${TEST_DEFAULT_FILE:-/etc/default/cloudflared}"
SERVICE_FILE="${TEST_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"

mkdir -p "${CONFIG_DIR}"
chmod 0700 "${CONFIG_DIR}"

if [ -n "${TUNNEL_TOKEN}" ]; then
    echo "==> [3/4] Configuring cloudflared for Dashboard Tunnel Token..."

    # Store token securely with 0600 permissions
    echo "${TUNNEL_TOKEN}" > "${CONFIG_DIR}/token"
    chmod 0600 "${CONFIG_DIR}/token"

    mkdir -p "$(dirname "${DEFAULT_FILE}")"
    cat <<EOF > "${DEFAULT_FILE}"
# Cloudflare Tunnel Token configuration
TUNNEL_TOKEN="${TUNNEL_TOKEN}"
EOF
    chmod 0600 "${DEFAULT_FILE}"
    echo "    Saved tunnel token to ${CONFIG_DIR}/token and ${DEFAULT_FILE} (0600)"
else
    echo "==> [3/4] Configuring /etc/cloudflared (local config mode)..."

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    EXAMPLE_CONFIG="${REPO_ROOT}/cloudflared/config.example.yml"

    if [ ! -f "${CONFIG_FILE}" ]; then
        if [ -f "${EXAMPLE_CONFIG}" ]; then
            cp "${EXAMPLE_CONFIG}" "${CONFIG_FILE}"
            echo "    Copied config template from ${EXAMPLE_CONFIG} to ${CONFIG_FILE}"
        else
            cat <<'EOF' > "${CONFIG_FILE}"
# Cloudflare Tunnel Pure IPv6 Configuration
tunnel: <TUNNEL_UUID>
credentials-file: /root/.cloudflared/<TUNNEL_UUID>.json
edge-ip-version: "6"
protocol: quic

ingress:
  - hostname: vault.yourdomain.com
    service: http://127.0.0.1:8080
  - service: http_status:404
EOF
            echo "    Generated default pure-IPv6 config template at ${CONFIG_FILE}"
        fi
    else
        echo "    Found existing configuration at ${CONFIG_FILE}; preserving existing file."
    fi

    # Enforce strict 0600 permissions on configuration and secrets
    chmod 0600 "${CONFIG_FILE}"
    if [ -d "/root/.cloudflared" ]; then
        chmod 0700 "/root/.cloudflared" 2>/dev/null || true
        chmod 0600 /root/.cloudflared/*.json 2>/dev/null || true
    fi
    echo "    Enforced 0600 permissions on ${CONFIG_FILE}"
fi

# 4. Configure and enable systemd service with auto-restart
echo "==> [4/4] Setting up systemd service unit..."
mkdir -p "$(dirname "${SERVICE_FILE}")"

if [ -n "${TUNNEL_TOKEN}" ]; then
    EXEC_START="/usr/bin/cloudflared tunnel --edge-ip-version 6 run --token ${TUNNEL_TOKEN}"
    SERVICE_PERMS="0600"
else
    EXEC_START="/usr/bin/cloudflared --config /etc/cloudflared/config.yml tunnel run"
    SERVICE_PERMS="0644"
fi

cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Cloudflare Tunnel (cloudflared) Pure IPv6 Service
Documentation=https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
TimeoutStartSec=0
ExecStart=${EXEC_START}
Restart=always
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

chmod "${SERVICE_PERMS}" "${SERVICE_FILE}"
echo "    Configured ${SERVICE_FILE} with Restart=always"

if [ "${VAULTZERO_TEST_MODE:-0}" != "1" ]; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl daemon-reload
        systemctl enable cloudflared.service
        echo "    cloudflared.service enabled in systemd"
    else
        echo "    systemd not active in current environment; service unit installed for boot"
    fi
else
    echo "    [TEST MODE] Skipping systemctl operations"
fi

echo "==> Setup complete!"
if [ -n "${TUNNEL_TOKEN}" ]; then
    echo "    1. Cloudflare Tunnel configured with Dashboard Tunnel Token."
    echo "    2. Edge IP version configured for Pure IPv6 (--edge-ip-version 6)."
    echo "    3. Start service: systemctl start cloudflared"
else
    echo "    1. Update /etc/cloudflared/config.yml with your TUNNEL_UUID and hostname."
    echo "    2. Copy your tunnel credentials JSON into /root/.cloudflared/<TUNNEL_UUID>.json."
    echo "    3. Start service: systemctl start cloudflared"
fi
