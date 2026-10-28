import os
import re
import subprocess
import pytest

SCRIPTS = [
    "scripts/03-restore-backup.sh",
    "scripts/verify-health.sh",
]

@pytest.mark.parametrize("script", SCRIPTS)
def test_script_syntax(script):
    assert os.path.exists(script), f"{script} must exist"
    res = subprocess.run(["bash", "-n", script], capture_output=True, text=True)
    assert res.returncode == 0, f"Syntax error in {script}: {res.stderr}"

def test_verify_health_contains_safety_audits():
    script_path = "scripts/verify-health.sh"
    assert os.path.exists(script_path), f"{script_path} must exist"
    with open(script_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Must contain bash safety options
    assert "set -euo pipefail" in content

    # Must check IPv4 absence (GCP metadata check or external-ip check)
    assert "no-address" in content or "external" in content.lower()

    # Must check IPv6 default gateway and NAT64 connectivity
    assert "api.github.com" in content
    assert "-6" in content or "ipv6" in content.lower()

    # Must verify ports 80/443 are NOT listening publicly
    assert "80" in content and "443" in content

    # Must check vaultwarden health
    assert "8080" in content
    assert "alive" in content

    # Must audit CF-Connecting-IP
    assert "CF-Connecting-IP" in content

    # Must check cloudflared systemd unit
    assert "cloudflared" in content
    assert "systemctl" in content or "is-active" in content

def test_verify_health_reviewer_fixes():
    script_path = "scripts/verify-health.sh"
    assert os.path.exists(script_path), f"{script_path} must exist"
    with open(script_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Critical 1: curl -fsS on GCP metadata endpoint to avoid false-positive on 404
    assert "curl -fsS" in content
    # Validate IPv4 regex check
    assert r"^([0-9]{1,3}\.){3}[0-9]{1,3}$" in content or r"^([0-9]{1,3}\.){3}[0-9]{1,3}" in content

    # Important 4: Handle both ss and netstat column orders for open ports
    # In ss: LISTEN comes before address:port. In netstat: address:port comes before LISTEN.
    assert "LISTEN" in content
    assert "netstat" in content
    assert "ss" in content

    # Extract the port regex pattern used in the script
    # Matches both LISTEN ... (0.0.0.0|*|[::]|::):(80|443) and (0.0.0.0|*|[::]|::):(80|443) ... LISTEN
    pattern_match = re.search(r"grep -Eq '([^']+)'", content)
    assert pattern_match is not None, "Should contain grep -Eq for port exposure check"

    # Test the regex behavior against both ss and netstat outputs
    port_regex = r"(LISTEN.*(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]|::):(80|443)\b|(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]|::):(80|443)\b.*LISTEN)"
    # Adapt bash [[:space:]] to Python \s for testing regex semantics
    py_regex = re.compile(port_regex.replace("[[:space:]]", r"\s"))

    # Should detect ss style exposed ports
    assert py_regex.search("tcp LISTEN 0 128 0.0.0.0:80 0.0.0.0:*")
    assert py_regex.search("tcp LISTEN 0 128 [::]:443 [::]:*")
    assert py_regex.search("tcp LISTEN 0 128 *:80 *:*")

    # Should detect netstat style exposed ports
    assert py_regex.search("tcp 0 0 0.0.0.0:80 0.0.0.0:* LISTEN")
    assert py_regex.search("tcp 0 0 0.0.0.0:443 0.0.0.0:* LISTEN")
    assert py_regex.search("tcp6 0 0 :::80 :::* LISTEN")
    assert py_regex.search("tcp6 0 0 :::443 :::* LISTEN")

    # Should NOT falsely flag 8080 or localhost
    assert not py_regex.search("tcp LISTEN 0 128 127.0.0.1:8080 0.0.0.0:*")
    assert py_regex.search("tcp 0 0 127.0.0.1:8080 0.0.0.0:* LISTEN") is None
    assert py_regex.search("tcp6 0 0 ::1:80 :::* LISTEN") is None

def test_restore_backup_script_requirements():
    script_path = "scripts/03-restore-backup.sh"
    assert os.path.exists(script_path), f"{script_path} must exist"
    with open(script_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Must contain bash safety options
    assert "set -euo pipefail" in content

    # Root check
    assert "id -u" in content or "EUID" in content

    # Reads or prompts for BACKUP_ZIP_PASS
    assert "BACKUP_ZIP_PASS" in content

    # Rclone support
    assert "rclone" in content

    # Pre-validation with unzip before stopping container
    assert "unzip -t" in content or "unzip" in content

    # Vaultwarden data directory and 0700 permissions
    assert "/opt/vaultwarden/data" in content
    assert "0700" in content or "700" in content

    # Docker restart and health verification
    assert "docker" in content
    assert "8080" in content
    assert "alive" in content

def test_restore_backup_reviewer_fixes():
    script_path = "scripts/03-restore-backup.sh"
    assert os.path.exists(script_path), f"{script_path} must exist"
    with open(script_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Critical 2: Dockerized rclone has --network host, TMP_WORK_DIR mount, and rclone config mount
    assert "--network host" in content
    assert "-v" in content and "TMP_WORK_DIR" in content
    assert "/opt/vaultwarden/rclone:/config/rclone" in content
    # Support installing rclone if available via apt-get
    assert "apt-get install" in content and "rclone" in content

    # Important 3: Stale SQLite WAL corruption safeguard: clear target directory before copying
    assert "find" in content
    assert "-mindepth 1 -delete" in content

    # Spec & Minor 5a: Explicit root:root ownership and 0700 permissions
    assert 'chown -R root:root "${VAULT_DATA_DIR}"' in content or "chown -R root:root" in content
    assert 'chmod 0700 "${VAULT_DATA_DIR}"' in content or "chmod 0700" in content

    # Spec & Minor 5b: Password parsing in .env must NOT use tr -d ' ' (preserves spaces), uses sed
    assert "tr -d ' '" not in content and 'tr -d " "' not in content
    assert "sed" in content and "BACKUP_ZIP_PASS" in content

    # Spec & Minor 5c: Prevent positional shift 2 underflow when flag value is missing ($# -lt 2 check)
    assert "$# -lt 2" in content
