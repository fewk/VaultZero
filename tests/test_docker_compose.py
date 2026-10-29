import os
import yaml
import pytest

def parse_env_list_or_dict(env_def):
    env_dict = {}
    if isinstance(env_def, list):
        for item in env_def:
            if "=" in item:
                k, v = item.split("=", 1)
                env_dict[k] = v
            else:
                env_dict[item] = None
    elif isinstance(env_def, dict):
        env_dict = {str(k): str(v) for k, v in env_def.items()}
    return env_dict

def test_docker_compose_schema_and_constraints():
    assert os.path.exists("docker-compose.yml"), "docker-compose.yml must exist"
    with open("docker-compose.yml", "r", encoding="utf-8") as f:
        compose = yaml.safe_load(f)

    services = compose.get("services", {})
    assert "vaultwarden" in services, "vaultwarden service must be defined"
    assert "backup" in services, "backup service must be defined"

    # Vaultwarden checks
    vw = services["vaultwarden"]
    assert vw.get("network_mode") == "host", "Vaultwarden must use host networking for IPv6"
    assert vw.get("restart") == "unless-stopped"
    assert vw.get("image") == "vaultwarden/server:latest"
    assert vw.get("container_name") == "vaultwarden"
    
    vw_env = parse_env_list_or_dict(vw.get("environment", []))
    assert vw_env.get("IP_HEADER") == "CF-Connecting-IP", "IP_HEADER must be CF-Connecting-IP"
    assert vw_env.get("SIGNUPS_ALLOWED") == "false"
    assert vw_env.get("ROCKET_ADDRESS") == "127.0.0.1", "ROCKET_ADDRESS must be 127.0.0.1"
    assert vw_env.get("ROCKET_PORT") == "8080"
    assert vw_env.get("LOGIN_RATELIMIT_MAX_BURST") == "10"
    assert vw_env.get("LOGIN_RATELIMIT_SECONDS") == "60"

    vw_volumes = vw.get("volumes", [])
    assert "/opt/vaultwarden/data:/data" in vw_volumes

    vw_logging = vw.get("logging", {})
    assert vw_logging.get("driver") == "json-file"
    assert str(vw_logging.get("options", {}).get("max-size")) == "10m"
    assert str(vw_logging.get("options", {}).get("max-file")) == "3"

    # Backup checks
    bk = services["backup"]
    assert bk.get("network_mode") == "host", "Backup must use host networking for IPv6 NAT64"
    assert bk.get("image") == "ttionya/vaultwarden-backup:latest"
    assert bk.get("container_name") == "vaultwarden-backup"
    assert bk.get("restart") == "unless-stopped"
    assert "vaultwarden" in bk.get("depends_on", [])

    bk_env = parse_env_list_or_dict(bk.get("environment", []))
    assert bk_env.get("CRON") == "0 3 * * *"
    assert "BACKUP_ZIP_PASS" in bk_env.get("ZIP_PASSWORD", "")

    bk_volumes = bk.get("volumes", [])
    assert "/opt/vaultwarden/data:/bitwarden/data:ro" in bk_volumes
    assert "/opt/vaultwarden/rclone:/config" in bk_volumes

    bk_logging = bk.get("logging", {})
    assert bk_logging.get("driver") == "json-file"
    assert str(bk_logging.get("options", {}).get("max-size")) == "5m"
    assert str(bk_logging.get("options", {}).get("max-file")) == "2"

def test_env_example_keys():
    assert os.path.exists(".env.example"), ".env.example must exist"
    with open(".env.example", "r", encoding="utf-8") as f:
        content = f.read()

    required_vars = [
        "DOMAIN",
        "ADMIN_TOKEN",
        "BACKUP_ZIP_PASS",
        "RCLONE_REMOTE_NAME",
        "TZ",
    ]
    for var in required_vars:
        assert var in content, f".env.example must define or document {var}"

def test_rclone_conf_example():
    rclone_path = os.path.join("rclone", "rclone.conf.example")
    assert os.path.exists(rclone_path), "rclone/rclone.conf.example must exist"
    with open(rclone_path, "r", encoding="utf-8") as f:
        content = f.read()

    assert "[r2]" in content
    assert "type = s3" in content
    assert "provider = Cloudflare" in content
    assert "access_key_id" in content
    assert "secret_access_key" in content
    assert "endpoint" in content
