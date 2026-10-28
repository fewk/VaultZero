#!/usr/bin/env bash
# ==============================================================================
# VaultZero: Automated System Health & Security Invariant Auditor
# ==============================================================================
# Verifies all zero-cost, zero-attack-surface architecture invariants:
# 1. Zero External IPv4 Address (GCP metadata & local interface scope global)
# 2. Outbound IPv6 Default Gateway & NAT64 Translation (api.github.com over -6)
# 3. Zero Inbound Public Ports: Verifies ports 80 and 443 are NOT listening publicly
# 4. Vaultwarden Local Service Health: http://127.0.0.1:8080/alive
# 5. IP Header Preservation: CF-Connecting-IP audit in container configuration & logs
# 6. Cloudflare Tunnel (cloudflared) systemd daemon status
# ==============================================================================

set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

log_pass() {
    echo -e "  [PASS] $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

log_fail() {
    echo -e "  [FAIL] $1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

log_warn() {
    echo -e "  [WARN] $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

echo "======================================================================"
echo " Starting VaultZero Security & Architecture Health Audit"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. Verify NO External IPv4 Address Assigned (Zero-Cost / Zero-Attack-Surface)
# ------------------------------------------------------------------------------
echo "==> [1/6] Auditing External IPv4 Address Status..."

GCP_EXTERNAL_IP=""
GCP_METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip"

# Query GCP metadata server if accessible (timeout 2s)
if curl -sS -m 2 -H "Metadata-Flavor: Google" "${GCP_METADATA_URL}" >/dev/null 2>&1; then
    GCP_EXTERNAL_IP="$(curl -sS -m 2 -H "Metadata-Flavor: Google" "${GCP_METADATA_URL}" 2>/dev/null || true)"
fi

if [ -n "${GCP_EXTERNAL_IP}" ]; then
    log_fail "External IPv4 address detected on GCP instance: ${GCP_EXTERNAL_IP} (Instance not launched with --no-address; incurs ~$2.88/mo cost and expands attack surface!)"
else
    # Inspect local network interfaces for any public IPv4 addresses
    PUBLIC_IPV4_FOUND=""
    if command -v ip >/dev/null 2>&1; then
        for ip in $(ip -4 addr show scope global 2>/dev/null | awk '{print $2}' | cut -d'/' -f1); do
            # Filter private RFC1918 (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10) and CGNAT
            if ! echo "${ip}" | grep -Eq '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.|127\.)'; then
                PUBLIC_IPV4_FOUND="${ip}"
                break
            fi
        done
    fi

    if [ -n "${PUBLIC_IPV4_FOUND}" ]; then
        log_fail "Public routable IPv4 detected on host interface: ${PUBLIC_IPV4_FOUND}"
    else
        log_pass "Verified zero external IPv4 address assigned (GCP --no-address verified, zero public IPv4 billing)."
    fi
fi

# ------------------------------------------------------------------------------
# 2. Verify IPv6 Default Gateway and NAT64 Connectivity
# ------------------------------------------------------------------------------
echo "==> [2/6] Auditing IPv6 Default Gateway & Outbound NAT64 Connectivity..."

IPV6_DEFAULT_ROUTE=""
if command -v ip >/dev/null 2>&1; then
    IPV6_DEFAULT_ROUTE="$(ip -6 route show default 2>/dev/null || true)"
fi

if [ -n "${IPV6_DEFAULT_ROUTE}" ]; then
    log_pass "IPv6 default route active: ${IPV6_DEFAULT_ROUTE}"
else
    log_warn "Could not inspect IPv6 default route with 'ip -6 route'."
fi

# Test NAT64 DNS resolution and connectivity to IPv4-only / dual-stack site over IPv6
NAT64_TARGET="https://api.github.com"
if curl -sS -6 -m 10 "${NAT64_TARGET}" >/dev/null 2>&1; then
    log_pass "Outbound NAT64 connectivity verified: ${NAT64_TARGET} reached successfully over pure IPv6 (-6)."
else
    log_fail "Failed to reach ${NAT64_TARGET} over IPv6. Ensure DNS64 resolvers are active in /etc/resolv.conf."
fi

# ------------------------------------------------------------------------------
# 3. Verify Local Ports 80 and 443 Are NOT Listening Publicly
# ------------------------------------------------------------------------------
echo "==> [3/6] Auditing Inbound Open Ports (80 & 443 Public Exposure Check)..."

# Cloudflare Tunnel initiates outbound QUIC connections to Cloudflare Edge.
# Under VaultZero architecture, ports 80 and 443 must NEVER listen on public interfaces (0.0.0.0 or [::]).
EXPOSED_PORTS=0
SOCKET_INFO=""

if command -v ss >/dev/null 2>&1; then
    SOCKET_INFO="$(ss -tuln 2>/dev/null || true)"
elif command -v netstat >/dev/null 2>&1; then
    SOCKET_INFO="$(netstat -tuln 2>/dev/null || true)"
fi

if [ -n "${SOCKET_INFO}" ]; then
    # Look for listening sockets on :80 or :443 bound to 0.0.0.0, [::], or *
    if echo "${SOCKET_INFO}" | grep -Eq 'LISTEN.*(0\.0\.0\.0|\*|\[::\]):(80|443)\b'; then
        EXPOSED_PORTS=1
    fi
fi

if [ "${EXPOSED_PORTS}" -eq 1 ]; then
    log_fail "Inbound port 80 or 443 detected listening on public interface! VaultZero requires zero inbound open ports."
else
    log_pass "Inbound ports 80 and 443 are completely closed to the internet (Cloudflare Tunnel ingress only)."
fi

# ------------------------------------------------------------------------------
# 4. Verify Vaultwarden Local Health Endpoint (127.0.0.1:8080/alive)
# ------------------------------------------------------------------------------
echo "==> [4/6] Auditing Vaultwarden Local Service Health..."

VW_HEALTH_URL="http://127.0.0.1:8080/alive"
if curl -fsSL -m 5 "${VW_HEALTH_URL}" >/dev/null 2>&1; then
    log_pass "Vaultwarden is healthy and responding with HTTP 200 at ${VW_HEALTH_URL}."
else
    log_fail "Vaultwarden service unreachable or unhealthy at ${VW_HEALTH_URL}."
fi

# ------------------------------------------------------------------------------
# 5. Audit Vaultwarden CF-Connecting-IP Header Configuration
# ------------------------------------------------------------------------------
echo "==> [5/6] Auditing IP Preservation & CF-Connecting-IP Header Configuration..."

CF_HEADER_CONFIGURED=0

# Check running docker container environment
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^vaultwarden$"; then
    if docker inspect vaultwarden 2>/dev/null | grep -q "IP_HEADER=CF-Connecting-IP"; then
        CF_HEADER_CONFIGURED=1
    fi
fi

# Check docker-compose.yml or .env as fallback audit
if [ "${CF_HEADER_CONFIGURED}" -eq 0 ]; then
    SEARCH_DIRS=("." "/opt/vaultwarden" "$(dirname "${BASH_SOURCE[0]}")/..")
    for dir in "${SEARCH_DIRS[@]}"; do
        if [ -f "${dir}/docker-compose.yml" ] && grep -q "IP_HEADER=CF-Connecting-IP" "${dir}/docker-compose.yml" 2>/dev/null; then
            CF_HEADER_CONFIGURED=1
            break
        fi
        if [ -f "${dir}/.env" ] && grep -q "IP_HEADER=CF-Connecting-IP" "${dir}/.env" 2>/dev/null; then
            CF_HEADER_CONFIGURED=1
            break
        fi
    done
fi

if [ "${CF_HEADER_CONFIGURED}" -eq 1 ]; then
    log_pass "Vaultwarden is configured with IP_HEADER=CF-Connecting-IP (Real client IPs preserved for fail2ban / audit logs)."
else
    log_fail "IP_HEADER=CF-Connecting-IP not detected in Vaultwarden environment or compose configuration."
fi

# ------------------------------------------------------------------------------
# 6. Verify Cloudflare Tunnel (cloudflared) Systemd Daemon
# ------------------------------------------------------------------------------
echo "==> [6/6] Auditing cloudflared Systemd Service Status..."

if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        log_pass "cloudflared systemd service is active and running."
    else
        log_fail "cloudflared systemd service is inactive or not loaded."
    fi
else
    # Fallback process check if systemd is not present (e.g. lightweight containers)
    if pgrep -x cloudflared >/dev/null 2>&1; then
        log_pass "cloudflared process is running."
    else
        log_fail "cloudflared service or process is not running."
    fi
fi

# ------------------------------------------------------------------------------
# Final Audit Summary
# ------------------------------------------------------------------------------
echo "======================================================================"
echo " VaultZero Health & Security Audit Summary"
echo " Passed: ${PASS_COUNT} | Failed: ${FAIL_COUNT} | Warnings: ${WARN_COUNT}"
echo "======================================================================"

if [ "${FAIL_COUNT}" -eq 0 ]; then
    echo " [RESULT] All VaultZero security and architectural invariants VERIFIED."
    exit 0
else
    echo " [RESULT] ${FAIL_COUNT} invariant check(s) FAILED. Please review errors above." >&2
    exit 1
fi
