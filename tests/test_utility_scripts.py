import os
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
