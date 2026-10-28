import os
import shutil
import subprocess
import yaml
import pytest

SCRIPT_PATH = "scripts/02-setup-cloudflared.sh"

@pytest.fixture
def cf_test_env():
    test_dir = "tests/.tmp_cf_test"
    if os.path.exists(test_dir):
        shutil.rmtree(test_dir, ignore_errors=True)
    os.makedirs(test_dir, exist_ok=True)
    paths = {
        "config_dir": f"{test_dir}/cloudflared",
        "service_file": f"{test_dir}/systemd/cloudflared.service",
        "default_file": f"{test_dir}/default/cloudflared",
        "root_dir": test_dir,
    }
    yield paths
    if os.path.exists(test_dir):
        shutil.rmtree(test_dir, ignore_errors=True)

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
    assert os.path.exists(SCRIPT_PATH), f"{SCRIPT_PATH} must exist"
    res = subprocess.run(["bash", "-n", SCRIPT_PATH], capture_output=True, text=True)
    assert res.returncode == 0, f"Bash syntax error in {SCRIPT_PATH}: {res.stderr}"

def test_setup_cloudflared_script_requirements():
    assert os.path.exists(SCRIPT_PATH), f"{SCRIPT_PATH} must exist"
    with open(SCRIPT_PATH, "r", encoding="utf-8") as f:
        content = f.read()

    # Verify bash safety flags
    assert "set -euo pipefail" in content, "Script must use 'set -euo pipefail'"

    # Verify architecture detection (amd64 / arm64)
    assert "amd64" in content, "Script must support amd64 architecture"
    assert "arm64" in content, "Script must support arm64 architecture"

    # Verify cloudflared deb download & installation
    assert "cloudflared" in content, "Script must install cloudflared"
    assert ".deb" in content, "Script must download/install official Debian package"

    # Verify positional parameter handling for TUNNEL_TOKEN
    assert 'TUNNEL_TOKEN="${1:-${TUNNEL_TOKEN:-}}"' in content or "TUNNEL_TOKEN=" in content

    # Verify pure IPv6 edge configuration in token mode ExecStart
    assert "tunnel --edge-ip-version 6 run --token" in content

    # Verify local config mode ExecStart
    assert "--config /etc/cloudflared/config.yml tunnel run" in content

    # Verify 0700 permissions on /etc/cloudflared directory
    assert "0700" in content

    # Verify 0600 permissions on secrets and configs
    assert "0600" in content

    # Verify systemd service configuration and auto-restart
    assert "systemd" in content or "systemctl" in content, "Script must configure systemd service"
    assert "Restart" in content or "restart" in content, "Script must configure auto-restart for cloudflared"

def test_setup_cloudflared_token_mode_execution(cf_test_env):
    """Test script execution when TUNNEL_TOKEN is provided as positional argument $1."""
    test_token = "eyJhIjoiYWJjZGVmZ2hpamsxMjM0NTYiLCJ0IjoidGVzdC10b2tlbi11dWlkIn0="
    config_dir = cf_test_env["config_dir"]
    service_file = cf_test_env["service_file"]
    default_file = cf_test_env["default_file"]

    cmd = (
        f"VAULTZERO_TEST_MODE=1 "
        f"TEST_CONFIG_DIR={config_dir} "
        f"TEST_SERVICE_FILE={service_file} "
        f"TEST_DEFAULT_FILE={default_file} "
        f"bash {SCRIPT_PATH} {test_token}"
    )
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
    assert res.returncode == 0, f"Script execution failed: {res.stderr}\n{res.stdout}"

    # Verify systemd service unit was generated for token mode
    assert os.path.exists(service_file), f"{service_file} must be created"
    with open(service_file, "r", encoding="utf-8") as f:
        service_content = f.read()

    expected_exec = f"ExecStart=/usr/bin/cloudflared tunnel --edge-ip-version 6 run --token {test_token}"
    assert expected_exec in service_content, f"Service file should contain: {expected_exec}"
    assert "Restart=always" in service_content

    # Verify token storage with 0600 permissions
    token_file = f"{config_dir}/token"
    assert os.path.exists(token_file), f"{token_file} must be created"
    with open(token_file, "r", encoding="utf-8") as f:
        assert f.read().strip() == test_token

    assert os.path.exists(default_file), f"{default_file} must be created"
    with open(default_file, "r", encoding="utf-8") as f:
        default_content = f.read()
    assert f'TUNNEL_TOKEN="{test_token}"' in default_content

def test_setup_cloudflared_local_mode_execution(cf_test_env):
    """Test script execution when no token is provided (local config mode)."""
    config_dir = cf_test_env["config_dir"]
    service_file = cf_test_env["service_file"]
    default_file = cf_test_env["default_file"]

    cmd = (
        f"VAULTZERO_TEST_MODE=1 "
        f"TEST_CONFIG_DIR={config_dir} "
        f"TEST_SERVICE_FILE={service_file} "
        f"TEST_DEFAULT_FILE={default_file} "
        f"bash {SCRIPT_PATH}"
    )
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
    assert res.returncode == 0, f"Script execution failed: {res.stderr}\n{res.stdout}"

    # Verify systemd service unit was generated for local config mode
    assert os.path.exists(service_file), f"{service_file} must be created"
    with open(service_file, "r", encoding="utf-8") as f:
        service_content = f.read()

    expected_exec = "ExecStart=/usr/bin/cloudflared --config /etc/cloudflared/config.yml tunnel run"
    assert expected_exec in service_content, f"Service file should contain: {expected_exec}"
    assert "Restart=always" in service_content

    # Verify config.yml template was deployed
    config_file = f"{config_dir}/config.yml"
    assert os.path.exists(config_file), f"{config_file} must be created in local mode"
    with open(config_file, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    assert cfg.get("edge-ip-version") == "6" or cfg.get("edge-ip-version") == 6
    assert cfg.get("protocol") == "quic"

def test_setup_cloudflared_token_via_env_var(cf_test_env):
    """Test script execution when TUNNEL_TOKEN is passed via environment variable."""
    test_token = "eyJhIjoiZW52LXRva2VuLWV4YW1wbGUifQ=="
    config_dir = cf_test_env["config_dir"]
    service_file = cf_test_env["service_file"]
    default_file = cf_test_env["default_file"]

    cmd = (
        f"VAULTZERO_TEST_MODE=1 "
        f"TUNNEL_TOKEN={test_token} "
        f"TEST_CONFIG_DIR={config_dir} "
        f"TEST_SERVICE_FILE={service_file} "
        f"TEST_DEFAULT_FILE={default_file} "
        f"bash {SCRIPT_PATH}"
    )
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
    assert res.returncode == 0, f"Script execution failed: {res.stderr}\n{res.stdout}"

    # Verify systemd service unit was generated for token mode
    assert os.path.exists(service_file), f"{service_file} must be created"
    with open(service_file, "r", encoding="utf-8") as f:
        service_content = f.read()

    expected_exec = f"ExecStart=/usr/bin/cloudflared tunnel --edge-ip-version 6 run --token {test_token}"
    assert expected_exec in service_content
