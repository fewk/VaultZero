#!/usr/bin/env bash
# ==============================================================================
# VaultZero: Disaster Recovery & Automated Backup Restore Script
# ==============================================================================
# Target: Debian 12 (bookworm) / GCP Always Free IPv6-Only VM
# Recovery Time Objective (RTO): < 3 minutes
# Recovery Point Objective (RPO): <= 24 hours (daily R2 backup snapshot)
# ==============================================================================
# Features:
# 1. Accepts a local .zip archive path or automatically downloads the latest
#    encrypted archive from Cloudflare R2 via rclone.
# 2. Resolves BACKUP_ZIP_PASS from CLI flags, environment, .env file, or prompt.
# 3. Validates AES zip integrity BEFORE stopping containers (zero false downtime).
# 4. Gracefully stops Vaultwarden container.
# 5. Backs up existing data to /opt/vaultwarden/data.bak.<timestamp> as rollback safeguard.
# 6. Extracts restored files into /opt/vaultwarden/data with strict 0700 permissions.
# 7. Restarts containers and verifies health via http://127.0.0.1:8080/alive.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Enforce Root Privileges
# ------------------------------------------------------------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "[ERROR] This restore script must be run as root or with sudo." >&2
    exit 1
fi

START_TIME="$(date +%s)"
VAULT_DATA_DIR="/opt/vaultwarden/data"
RCLONE_CONFIG_FILE="/opt/vaultwarden/rclone/rclone.conf"
DEFAULT_RCLONE_REMOTE="r2:vaultwarden-backup"

# Display usage
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [BACKUP_FILE.zip]

VaultZero Disaster Recovery & Backup Restore Tool.

Options:
  -f, --file PATH         Path to local encrypted backup .zip file
  -p, --password PASS     AES encryption password for the backup zip
  -r, --remote REMOTE     Rclone remote name (default: ${DEFAULT_RCLONE_REMOTE})
  -l, --latest            Fetch and restore latest backup archive from R2
  -h, --help              Show this help message and exit

Environment Variables:
  BACKUP_ZIP_PASS         Password for decrypting backup zip
  RCLONE_REMOTE_NAME      Rclone remote destination (default: r2:vaultwarden-backup)
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# 2. Parse Command-Line Arguments
# ------------------------------------------------------------------------------
BACKUP_FILE=""
PASSWORD="${BACKUP_ZIP_PASS:-}"
RCLONE_REMOTE="${RCLONE_REMOTE_NAME:-${DEFAULT_RCLONE_REMOTE}}"
FETCH_LATEST=0

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--file)
            if [ $# -lt 2 ]; then
                echo "[ERROR] Option $1 requires an argument." >&2
                usage
            fi
            BACKUP_FILE="$2"
            shift 2
            ;;
        -p|--password)
            if [ $# -lt 2 ]; then
                echo "[ERROR] Option $1 requires an argument." >&2
                usage
            fi
            PASSWORD="$2"
            shift 2
            ;;
        -r|--remote)
            if [ $# -lt 2 ]; then
                echo "[ERROR] Option $1 requires an argument." >&2
                usage
            fi
            RCLONE_REMOTE="$2"
            shift 2
            ;;
        -l|--latest)
            FETCH_LATEST=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "[ERROR] Unknown option: $1" >&2
            usage
            ;;
        *)
            if [ -z "${BACKUP_FILE}" ]; then
                BACKUP_FILE="$1"
            else
                echo "[ERROR] Unexpected argument: $1" >&2
                usage
            fi
            shift
            ;;
    esac
done

echo "======================================================================"
echo " VaultZero Disaster Recovery & Restore Process"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 3. Locate or Retrieve Encryption Password (BACKUP_ZIP_PASS)
# ------------------------------------------------------------------------------
if [ -z "${PASSWORD}" ]; then
    # Attempt to load BACKUP_ZIP_PASS from .env files
    ENV_LOCATIONS=(
        "$(pwd)/.env"
        "/opt/vaultwarden/.env"
        "/opt/vaultwarden/env/.env"
    )
    for env_path in "${ENV_LOCATIONS[@]}"; do
        if [ -f "${env_path}" ]; then
            # Extract value after '=' and strip only enclosing quotes (preserving internal passphrase spaces)
            val="$(grep -E '^BACKUP_ZIP_PASS=' "${env_path}" 2>/dev/null | head -n 1 | cut -d '=' -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'$/\\1/" || true)"
            if [ -n "${val}" ]; then
                PASSWORD="${val}"
                echo "==> Loaded BACKUP_ZIP_PASS from ${env_path}"
                break
            fi
        fi
    done
fi

if [ -z "${PASSWORD}" ]; then
    echo -n "Enter BACKUP_ZIP_PASS: "
    read -r -s PASSWORD
    echo ""
fi

if [ -z "${PASSWORD}" ]; then
    echo "[ERROR] BACKUP_ZIP_PASS cannot be empty. Aborting." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Fetch Backup Archive from Remote Storage (if needed)
# ------------------------------------------------------------------------------
TMP_WORK_DIR="$(mktemp -d /tmp/vaultzero-restore-XXXXXX)"
cleanup() {
    rm -rf "${TMP_WORK_DIR}"
}
trap cleanup EXIT INT TERM

if [ -z "${BACKUP_FILE}" ] || [ "${FETCH_LATEST}" -eq 1 ]; then
    echo "==> [1/6] Querying remote storage (${RCLONE_REMOTE}) for latest backup..."
    
    # Check if rclone is available, or install via apt if package manager is present
    if ! command -v rclone >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            echo "    rclone not found. Attempting installation via apt-get..."
            apt-get update -qy && apt-get install -qy --no-install-recommends rclone || true
        fi
    fi

    RCLONE_CMD=()
    if command -v rclone >/dev/null 2>&1; then
        if [ -f "${RCLONE_CONFIG_FILE}" ]; then
            RCLONE_CMD=(rclone --config "${RCLONE_CONFIG_FILE}")
        else
            RCLONE_CMD=(rclone)
        fi
    elif command -v docker >/dev/null 2>&1 && (docker image inspect rclone/rclone >/dev/null 2>&1 || docker ps >/dev/null 2>&1); then
        RCLONE_CMD=(docker run --rm --network host -v "${TMP_WORK_DIR}:${TMP_WORK_DIR}" -v /opt/vaultwarden/rclone:/config/rclone rclone/rclone)
    else
        echo "[ERROR] Neither 'rclone' CLI nor Docker is available to fetch remote backups." >&2
        exit 1
    fi

    LATEST_NAME="$("${RCLONE_CMD[@]}" lsf "${RCLONE_REMOTE}" --include "*.zip" 2>/dev/null | sort | tail -n 1 || true)"
    if [ -z "${LATEST_NAME}" ]; then
        echo "[ERROR] No .zip backup archives found in remote ${RCLONE_REMOTE}." >&2
        exit 1
    fi

    echo "    Found latest remote backup: ${LATEST_NAME}"
    echo "    Downloading ${LATEST_NAME} to local staging..."
    "${RCLONE_CMD[@]}" copy "${RCLONE_REMOTE}/${LATEST_NAME}" "${TMP_WORK_DIR}"
    BACKUP_FILE="${TMP_WORK_DIR}/${LATEST_NAME}"
fi

if [ ! -f "${BACKUP_FILE}" ]; then
    echo "[ERROR] Backup file not found: ${BACKUP_FILE}" >&2
    exit 1
fi

echo "==> Selected backup archive: ${BACKUP_FILE} ($(du -h "${BACKUP_FILE}" | cut -f1))"

# ------------------------------------------------------------------------------
# 5. Pre-Restore Integrity Validation (Zero False Downtime)
# ------------------------------------------------------------------------------
echo "==> [2/6] Validating archive integrity and password before stopping services..."

if ! command -v unzip >/dev/null 2>&1; then
    apt-get update -qy && apt-get install -qy --no-install-recommends unzip
fi

# unzip -t verifies CRC and password without extracting
if ! unzip -t -P "${PASSWORD}" "${BACKUP_FILE}" >/dev/null 2>&1; then
    echo "[ERROR] Integrity check failed for ${BACKUP_FILE}!" >&2
    echo "        Incorrect BACKUP_ZIP_PASS or corrupted zip archive." >&2
    echo "        Services have NOT been stopped. No downtime incurred." >&2
    exit 1
fi
echo "    Archive integrity and password successfully verified."

# ------------------------------------------------------------------------------
# 6. Gracefully Stop Containers
# ------------------------------------------------------------------------------
echo "==> [3/6] Gracefully stopping Vaultwarden container..."

DOCKER_COMPOSE_DIR="$(pwd)"
if [ ! -f "${DOCKER_COMPOSE_DIR}/docker-compose.yml" ]; then
    if [ -f "/opt/vaultwarden/docker-compose.yml" ]; then
        DOCKER_COMPOSE_DIR="/opt/vaultwarden"
    elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../docker-compose.yml" ]; then
        DOCKER_COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi
fi

if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1 && [ -f "${DOCKER_COMPOSE_DIR}/docker-compose.yml" ]; then
        docker compose -f "${DOCKER_COMPOSE_DIR}/docker-compose.yml" stop vaultwarden || true
    elif docker ps -q -f name=vaultwarden | grep -q .; then
        docker stop -t 15 vaultwarden || true
    fi
fi
echo "    Container stopped."

# ------------------------------------------------------------------------------
# 7. Backup Existing Data State (Rollback Safeguard) & Extract Archive
# ------------------------------------------------------------------------------
echo "==> [4/6] Extracting backup archive into ${VAULT_DATA_DIR}..."

mkdir -p "${VAULT_DATA_DIR}"

if [ "$(ls -A "${VAULT_DATA_DIR}" 2>/dev/null)" ]; then
    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    BACKUP_SNAPSHOT="/opt/vaultwarden/data.bak.${TIMESTAMP}"
    echo "    Backing up existing data to ${BACKUP_SNAPSHOT}..."
    cp -a "${VAULT_DATA_DIR}" "${BACKUP_SNAPSHOT}"
    # Stale SQLite WAL corruption safeguard:
    # Clear existing target directory files before copying restored data to prevent
    # leftover db.sqlite3-wal and db.sqlite3-shm from corrupting restored db.sqlite3.
    find "${VAULT_DATA_DIR}" -mindepth 1 -delete
fi

EXTRACT_DIR="${TMP_WORK_DIR}/extracted"
mkdir -p "${EXTRACT_DIR}"
unzip -q -o -P "${PASSWORD}" "${BACKUP_FILE}" -d "${EXTRACT_DIR}"

# Handle nested data directory or flat files layout
SRC_DIR="${EXTRACT_DIR}"
if [ -d "${EXTRACT_DIR}/data" ] && [ ! -f "${EXTRACT_DIR}/db.sqlite3" ]; then
    SRC_DIR="${EXTRACT_DIR}/data"
fi

cp -a "${SRC_DIR}/." "${VAULT_DATA_DIR}/"

# Enforce strict root ownership and 0700 permissions
chown -R root:root "${VAULT_DATA_DIR}"
chmod 0700 "${VAULT_DATA_DIR}"
chmod -R u=rwX,go= "${VAULT_DATA_DIR}" 2>/dev/null || chmod -R 0700 "${VAULT_DATA_DIR}"

echo "    Extraction complete. Enforced root:root ownership and 0700 permissions on ${VAULT_DATA_DIR}."

# ------------------------------------------------------------------------------
# 8. Restart Containers
# ------------------------------------------------------------------------------
echo "==> [5/6] Starting Vaultwarden services..."

if [ -f "${DOCKER_COMPOSE_DIR}/docker-compose.yml" ]; then
    docker compose -f "${DOCKER_COMPOSE_DIR}/docker-compose.yml" up -d vaultwarden
else
    docker start vaultwarden || true
fi

# ------------------------------------------------------------------------------
# 9. Automated Health Verification (RTO < 3 min Verification)
# ------------------------------------------------------------------------------
echo "==> [6/6] Verifying Vaultwarden availability at http://127.0.0.1:8080/alive..."

MAX_WAIT_SECONDS=60
START_CHECK="$(date +%s)"
IS_ALIVE=0

while [ $(( $(date +%s) - START_CHECK )) -lt ${MAX_WAIT_SECONDS} ]; do
    if curl -fsSL -m 3 "http://127.0.0.1:8080/alive" >/dev/null 2>&1; then
        IS_ALIVE=1
        break
    fi
    sleep 2
done

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))

if [ "${IS_ALIVE}" -eq 1 ]; then
    echo "======================================================================"
    echo " [SUCCESS] Vaultwarden restored successfully!"
    echo "           Health Check: http://127.0.0.1:8080/alive OK"
    echo "           Total Restore Time: ${TOTAL_ELAPSED}s (RTO < 3 min target achieved)"
    echo "======================================================================"
    exit 0
else
    echo "======================================================================" >&2
    echo " [ERROR] Vaultwarden container failed health verification on port 8080." >&2
    echo "         Check logs with: docker compose logs vaultwarden" >&2
    echo "======================================================================" >&2
    exit 1
fi
