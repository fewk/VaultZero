# tests/test_repo_structure.py
import os
import pytest

REQUIRED_FILES = [
    ".gitignore",
    "LICENSE",
    "README.md",
    "docker-compose.yml",
    ".env.example",
]

SENSITIVE_PATTERNS = [
    ".env",
    "rclone.conf",
    "data/",
    "*.enc",
    "*.zip",
    "*.key",
    ".cloudflared/",
]

def test_sensitive_files_ignored():
    assert os.path.exists(".gitignore"), ".gitignore must exist"
    with open(".gitignore", "r", encoding="utf-8") as f:
        content = f.read()
    for pattern in SENSITIVE_PATTERNS:
        assert pattern in content, f"{pattern} must be excluded in .gitignore"
