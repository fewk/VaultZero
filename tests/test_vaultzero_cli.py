import os
import subprocess
import pytest

def test_vaultzero_cli_syntax():
    cli_path = "vaultzero.sh"
    assert os.path.exists(cli_path), "vaultzero.sh must exist in repository root"
    res = subprocess.run(["bash", "-n", cli_path], capture_output=True, text=True)
    assert res.returncode == 0, f"Syntax error in vaultzero.sh: {res.stderr}"

def test_vaultzero_cli_help_menu():
    cli_path = "vaultzero.sh"
    res = subprocess.run(["bash", cli_path, "help"], capture_output=True, text=True)
    assert res.returncode == 0
    output = res.stdout

    expected_commands = [
        "status",
        "verify",
        "up",
        "down",
        "restart",
        "logs",
        "backup",
        "restore",
        "register",
        "setup",
    ]
    for cmd in expected_commands:
        assert cmd in output, f"Help menu should document '{cmd}' command"

def test_vaultzero_cli_unknown_command():
    cli_path = "vaultzero.sh"
    res = subprocess.run(["bash", cli_path, "invalid_cmd_xyz"], capture_output=True, text=True)
    assert res.returncode == 1
    assert "Unknown command" in res.stderr

def test_agents_markdown_exists_and_contains_guardrails():
    agents_path = "AGENTS.md"
    assert os.path.exists(agents_path), "AGENTS.md must exist in repository root"
    with open(agents_path, "r", encoding="utf-8") as f:
        content = f.read()

    assert "--no-address" in content
    assert "35.235.240.0/20" in content
    assert "network_mode: host" in content or "network_mode: \"host\"" in content
    assert "CF-Connecting-IP" in content
    assert "vaultzero.sh" in content
