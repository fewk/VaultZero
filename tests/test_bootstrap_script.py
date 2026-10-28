import os
import subprocess
import pytest

SCRIPT_PATH = "scripts/01-bootstrap-vm.sh"

def test_bootstrap_script_syntax_and_keywords():
    assert os.path.exists(SCRIPT_PATH), f"{SCRIPT_PATH} must exist"
    res = subprocess.run(["bash", "-n", SCRIPT_PATH], capture_output=True, text=True)
    assert res.returncode == 0, f"Bash syntax error in {SCRIPT_PATH}: {res.stderr}"

    with open(SCRIPT_PATH, "r", encoding="utf-8") as f:
        content = f.read()

    # Must contain bash safety options
    assert "set -euo pipefail" in content

    # Must check root privileges
    assert "EUID" in content or "id -u" in content

    # Must contain NAT64 DNS resolvers
    assert "2a01:4ff:f0:9876::1" in content
    assert "2a00:1098:2b::1" in content
    assert "2606:4700:4700::1111" in content

    # Must validate NAT64 outbound connectivity to IPv4 sites
    assert "api.github.com" in content

    # Must setup swapfile of 1GB and configure swappiness
    assert "swapfile" in content
    assert "swappiness" in content
    assert "fstab" in content

    # Must install docker and compose plugin
    assert "docker" in content
    assert "docker-compose-plugin" in content

    # Must create directory hierarchy under /opt/vaultwarden
    assert "/opt/vaultwarden" in content
    assert "data" in content
    assert "rclone" in content
    assert "env" in content
    assert "0700" in content or "700" in content

def test_bootstrap_script_dns64_config():
    with open(SCRIPT_PATH, "r", encoding="utf-8") as f:
        content = f.read()

    # Verify Ashburn & Amsterdam NAT64 gateways and Cloudflare fallback
    assert "2a01:4ff:f0:9876::1" in content, "Missing Ashburn NAT64 resolver"
    assert "2a00:1098:2b::1" in content, "Missing Amsterdam NAT64 resolver"
    assert "2606:4700:4700::1111" in content, "Missing Cloudflare IPv6 resolver"
    assert "/etc/resolv.conf" in content, "Must configure /etc/resolv.conf"
    assert "chattr" in content, "Must use chattr to protect resolv.conf against cloud-init/dhcp overwrites"

def test_bootstrap_script_swap_idempotency():
    with open(SCRIPT_PATH, "r", encoding="utf-8") as f:
        content = f.read()

    # Verify swap sizing and permissions
    assert "1024" in content or "1G" in content, "Swap must be configured to 1GB"
    assert "chmod 600" in content, "Swapfile must have 600 permissions"
    assert "mkswap" in content, "Must initialize swap with mkswap"
    assert "swapon" in content, "Must activate swap with swapon"
    assert "fstab" in content, "Must persist swap in /etc/fstab"
    assert "vm.swappiness=10" in content, "Must configure swappiness to 10"

def test_bootstrap_script_docker_installation():
    with open(SCRIPT_PATH, "r", encoding="utf-8") as f:
        content = f.read()

    # Verify official Docker apt repository setup
    assert "download.docker.com" in content, "Must use official Docker repository"
    assert "docker-ce" in content, "Must install docker-ce"
    assert "docker-compose-plugin" in content, "Must install docker-compose-plugin"
    assert "containerd.io" in content, "Must install containerd.io"
    assert "keyrings" in content, "Must store GPG key in /etc/apt/keyrings"

def test_bootstrap_script_vaultwarden_directory_hierarchy():
    with open(SCRIPT_PATH, "r", encoding="utf-8") as f:
        content = f.read()

    # Verify directory paths
    assert "/opt/vaultwarden/data" in content or "${BASE_DIR}/data" in content
    assert "/opt/vaultwarden/rclone" in content or "${BASE_DIR}/rclone" in content
    assert "/opt/vaultwarden/env" in content or "${BASE_DIR}/env" in content
    assert "0700" in content or "700" in content
