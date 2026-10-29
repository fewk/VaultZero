#!/usr/bin/env bash
# ==============================================================================
# VaultZero: Unified Operator & Agent CLI
# Manage Vaultwarden, Cloudflare Tunnel, backups, and security health checks.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}"

# Locate docker-compose directory (prioritize /opt/vaultwarden if exists)
if [ -d "/opt/vaultwarden" ] && [ -f "/opt/vaultwarden/docker-compose.yml" ]; then
    COMPOSE_DIR="/opt/vaultwarden"
else
    COMPOSE_DIR="${BASE_DIR}"
fi

show_help() {
    cat <<EOF
VaultZero Management CLI

Usage:
    ./vaultzero.sh <command> [arguments]

Commands:
    status              Check operational status of containers, tunnel, memory & ports
    verify              Execute 6-point invariant security & health audit
    up | start          Start Vaultwarden and backup containers in background
    down | stop         Stop Vaultwarden and backup containers
    restart             Restart Docker containers and cloudflared tunnel service
    logs [service]      View logs for vaultwarden, backup, or tunnel (default: all)
    backup              Trigger an immediate zero-lock hot backup to Cloudflare R2
    restore [args]      Restore database & data from R2 or local archive (03-restore-backup.sh)
    register [on|off]   Temporarily open or lock down user registration
    setup [TOKEN]       Run automated VM bootstrap and Cloudflare tunnel installer
    fix-dns             Restore and lock NAT64 DNS resolvers in /etc/resolv.conf
    help                Show this help message

Examples:
    ./vaultzero.sh status
    ./vaultzero.sh verify
    ./vaultzero.sh register on
    ./vaultzero.sh register off
    ./vaultzero.sh logs vaultwarden
    ./vaultzero.sh backup
    ./vaultzero.sh restore --latest
EOF
}

cmd_status() {
    echo "======================================================================"
    echo " [VaultZero Status Overview]"
    echo "======================================================================"

    echo "--> [1] Docker Containers:"
    if command -v docker >/dev/null 2>&1; then
        docker ps --filter "name=vaultwarden" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
    else
        echo "    Docker is not installed or not running."
    fi

    echo ""
    echo "--> [2] Cloudflare Tunnel Service (cloudflared):"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl is-active cloudflared.service >/dev/null 2>&1 && echo "    cloudflared: ACTIVE (running)" || echo "    cloudflared: INACTIVE or FAILED"
    else
        echo "    Systemd is not available in current environment."
    fi

    echo ""
    echo "--> [3] Local Listening Ports (8080):"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -E ':8080\b' || echo "    Port 8080 is not currently listening."
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep -E ':8080\b' || echo "    Port 8080 is not currently listening."
    else
        echo "    Socket inspection tools (ss/netstat) not found."
    fi

    echo ""
    echo "--> [4] Memory & Swap Utilization:"
    if command -v free >/dev/null 2>&1; then
        free -h || true
    fi
    echo "======================================================================"
}

cmd_verify() {
    local verify_script="${BASE_DIR}/scripts/verify-health.sh"
    if [ -f "${verify_script}" ]; then
        bash "${verify_script}"
    else
        echo "[ERROR] Verification script not found at ${verify_script}" >&2
        exit 1
    fi
}

cmd_up() {
    echo "==> Starting VaultZero containers..."
    docker compose -f "${COMPOSE_DIR}/docker-compose.yml" up -d
    echo "==> Containers started."
}

cmd_down() {
    echo "==> Stopping VaultZero containers..."
    docker compose -f "${COMPOSE_DIR}/docker-compose.yml" down
    echo "==> Containers stopped."
}

cmd_restart() {
    echo "==> Restarting VaultZero containers (reloading configuration)..."
    docker compose -f "${COMPOSE_DIR}/docker-compose.yml" up -d --force-recreate
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        echo "==> Restarting cloudflared.service..."
        systemctl restart cloudflared.service || true
    fi
    echo "==> Restart complete."
}

cmd_register() {
    local action="${1:-}"
    local compose_file="${COMPOSE_DIR}/docker-compose.yml"
    local env_file="${COMPOSE_DIR}/.env"

    if [ ! -f "${compose_file}" ]; then
        echo "[ERROR] Compose file not found at ${compose_file}" >&2
        exit 1
    fi

    case "${action}" in
        on|enable|true)
            echo "==> Enabling new user registration..."
            sed -i 's/SIGNUPS_ALLOWED=false/SIGNUPS_ALLOWED=true/' "${compose_file}"
            [ -f "${env_file}" ] && sed -i 's/SIGNUPS_ALLOWED=false/SIGNUPS_ALLOWED=true/' "${env_file}" || true
            docker compose -f "${compose_file}" up -d --force-recreate vaultwarden
            echo "==> [SUCCESS] Registration is now OPEN. Visit your vault to create your account."
            echo "    IMPORTANT: Lock registration when done: ./vaultzero.sh register off"
            ;;
        off|disable|false)
            echo "==> Disabling new user registration (Securing vault)..."
            sed -i 's/SIGNUPS_ALLOWED=true/SIGNUPS_ALLOWED=false/' "${compose_file}"
            [ -f "${env_file}" ] && sed -i 's/SIGNUPS_ALLOWED=true/SIGNUPS_ALLOWED=false/' "${env_file}" || true
            docker compose -f "${compose_file}" up -d --force-recreate vaultwarden
            echo "==> [SUCCESS] Registration is now CLOSED."
            ;;
        *)
            echo "Usage: ./vaultzero.sh register [on|off]" >&2
            exit 1
            ;;
    esac
}

cmd_logs() {
    local target="${1:-all}"
    case "${target}" in
        vaultwarden)
            docker compose -f "${COMPOSE_DIR}/docker-compose.yml" logs -f vaultwarden
            ;;
        backup)
            docker compose -f "${COMPOSE_DIR}/docker-compose.yml" logs -f backup
            ;;
        tunnel|cloudflared)
            journalctl -u cloudflared.service -f -n 100
            ;;
        all)
            docker compose -f "${COMPOSE_DIR}/docker-compose.yml" logs --tail 50
            ;;
        *)
            echo "[ERROR] Unknown service for logs: ${target}. Choose from: vaultwarden, backup, tunnel, all" >&2
            exit 1
            ;;
    esac
}

cmd_backup() {
    echo "==> Triggering on-demand hot backup via vaultwarden-backup container..."
    if docker ps --format '{{.Names}}' | grep -q '^vaultwarden-backup$'; then
        docker exec vaultwarden-backup /app/backup.sh
        echo "==> [SUCCESS] Hot backup execution completed."
    else
        echo "[ERROR] Container vaultwarden-backup is not running." >&2
        exit 1
    fi
}

cmd_restore() {
    local restore_script="${BASE_DIR}/scripts/03-restore-backup.sh"
    if [ -f "${restore_script}" ]; then
        bash "${restore_script}" "$@"
    else
        echo "[ERROR] Restore script not found at ${restore_script}" >&2
        exit 1
    fi
}

cmd_setup() {
    local token="${1:-}"
    local b_script="${BASE_DIR}/scripts/01-bootstrap-vm.sh"
    local c_script="${BASE_DIR}/scripts/02-setup-cloudflared.sh"

    if [ ! -f "${b_script}" ] || [ ! -f "${c_script}" ]; then
        echo "[ERROR] Setup scripts missing in ${BASE_DIR}/scripts" >&2
        exit 1
    fi

    echo "==> [1/2] Running VM bootstrap..."
    bash "${b_script}"

    echo "==> [2/2] Setting up Cloudflare tunnel..."
    if [ -n "${token}" ]; then
        bash "${c_script}" "${token}"
    else
        bash "${c_script}"
    fi

    echo "==> Setup complete! Next: configure /opt/vaultwarden/.env and run: ./vaultzero.sh up"
}

cmd_fix_dns() {
    echo "==> Restoring and locking pure DNS64/NAT64 resolvers in /etc/resolv.conf..."
    if command -v chattr >/dev/null 2>&1; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi
    cat <<'EOF' > /etc/resolv.conf
# Managed by VaultZero (Pure DNS64 / NAT64 Resolvers)
nameserver 2a01:4ff:f0:9876::1
nameserver 2001:67c:2960::64
nameserver 2a00:1098:2b::1
options edns0 timeout:2 attempts:3
EOF
    if [ -d /etc/dhcp ]; then
        cat <<'EOF' > /etc/dhcp/dhclient.conf
supersede domain-name-servers 2a01:4ff:f0:9876::1, 2001:67c:2960::64, 2a00:1098:2b::1;
EOF
    fi
    if command -v chattr >/dev/null 2>&1; then
        chattr +i /etc/resolv.conf 2>/dev/null || true
    fi
    echo "    NAT64 DNS resolvers locked with chattr +i."
}

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
COMMAND="${1:-help}"
shift || true

case "${COMMAND}" in
    status)
        cmd_status
        ;;
    verify)
        cmd_verify
        ;;
    up|start)
        cmd_up
        ;;
    down|stop)
        cmd_down
        ;;
    restart)
        cmd_restart
        ;;
    logs)
        cmd_logs "$@"
        ;;
    backup)
        cmd_backup
        ;;
    restore)
        cmd_restore "$@"
        ;;
    register)
        cmd_register "$@"
        ;;
    setup)
        cmd_setup "$@"
        ;;
    fix-dns|dns-fix)
        cmd_fix_dns
        ;;
    help|-h|--help)
        show_help
        ;;
    *)
        echo "[ERROR] Unknown command: ${COMMAND}" >&2
        echo "" >&2
        show_help
        exit 1
        ;;
esac
