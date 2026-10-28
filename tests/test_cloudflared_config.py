import os
import subprocess
import yaml
import pytest

def test_cloudflared_yaml_config():
    config_path = "cloudflared/config.example.yml"
    assert os.path.exists(config_path), f"{config_path} must exist"
    with open(config_path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    assert cfg.get("edge-ip-version") == "6" or cfg.get("edge-ip-version") == 6, "edge-ip-version must be set to 6"
    assert cfg.get("protocol") == "quic", "protocol must be quic"
    assert "tunnel" in cfg, "tunnel key must be present in config"
    assert "credentials-file" in cfg, "credentials-file must be present in config"

    ingress = cfg.get("ingress", [])
    assert any("8080" in item.get("service", "") for item in ingress), "ingress must forward to port 8080"
    assert ingress[-1].get("service") == "http_status:404", "last ingress rule must be http_status:404 catch-all"

def test_setup_cloudflared_script_syntax():
    script = "scripts/02-setup-cloudflared.sh"
    assert os.path.exists(script), f"{script} must exist"
    res = subprocess.run(["bash", "-n", script], capture_output=True, text=True)
    assert res.returncode == 0, f"Bash syntax error in {script}: {res.stderr}"

def test_setup_cloudflared_script_requirements():
    script = "scripts/02-setup-cloudflared.sh"
    assert os.path.exists(script), f"{script} must exist"
    with open(script, "r", encoding="utf-8") as f:
        content = f.read()

    # Verify bash safety flags
    assert "set -euo pipefail" in content, "Script must use 'set -euo pipefail'"

    # Verify architecture detection (amd64 / arm64)
    assert "amd64" in content, "Script must support amd64 architecture"
    assert "arm64" in content, "Script must support arm64 architecture"

    # Verify cloudflared deb download & installation
    assert "cloudflared" in content, "Script must install cloudflared"
    assert ".deb" in content, "Script must download/install official Debian package"

    # Verify 0600 permissions on config
    assert "0600" in content or "600" in content, "Script must enforce 0600 permissions on config"

    # Verify systemd service configuration and auto-restart
    assert "systemd" in content or "systemctl" in content, "Script must configure systemd service"
    assert "Restart" in content or "restart" in content, "Script must configure auto-restart for cloudflared"
