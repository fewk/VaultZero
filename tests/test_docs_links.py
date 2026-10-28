"""
Unit tests for documentation integrity, link validity, and required configuration flags.
"""
import os
import re
import pytest

DOC_FILES = [
    "README.md",
    "docs/gcp-deployment.md",
    "docs/cloudflare-setup.md",
    "docs/superpowers/specs/2026-10-28-vaultwarden-gcp-ipv6-design.md",
]


@pytest.mark.parametrize("doc", DOC_FILES)
def test_doc_exists_and_not_empty(doc):
    """Verify all critical documentation files exist and have substantive content."""
    assert os.path.exists(doc), f"Missing expected document: {doc}"
    assert os.path.getsize(doc) > 200, f"Document {doc} is too short (< 200 bytes)"


def test_gcp_doc_contains_required_flags():
    """Verify docs/gcp-deployment.md contains essential Always Free & IAP constraints."""
    with open("docs/gcp-deployment.md", "r", encoding="utf-8") as f:
        content = f.read()

    assert "--no-address" in content, "Must emphasize --no-address to avoid IPv4 billing"
    assert "e2-micro" in content, "Must specify e2-micro instance type"
    assert "us-west1" in content, "Must specify us-west1 or Always Free region"
    assert "35.235.240.0/20" in content, "Must include GCP IAP CIDR block"
    assert "IPV4_IPV6" in content, "Must specify dual-stack IPV4_IPV6 subnet configuration"
    assert "--tunnel-through-iap" in content, "Must include IAP SSH command"


def test_cloudflare_doc_contains_required_configs():
    """Verify docs/cloudflare-setup.md contains complete WAF, Access, and R2 instructions."""
    with open("docs/cloudflare-setup.md", "r", encoding="utf-8") as f:
        content = f.read()

    assert "127.0.0.1:8080" in content, "Must route public hostname to 127.0.0.1:8080"
    assert "/identity/connect/token" in content, "Must configure rate limit on /identity/connect/token"
    assert "POST" in content, "Must specify POST method for login rate limiting"
    assert "/admin" in content, "Must protect /admin endpoint with Zero Trust Access"
    assert "vaultwarden-backup" in content, "Must configure vaultwarden-backup bucket"
    assert "Managed Challenge" in content, "Must warn against using Managed Challenge on /api/*"


def test_readme_links_to_docs():
    """Verify README.md contains links to the step-by-step deployment guides."""
    with open("README.md", "r", encoding="utf-8") as f:
        readme_content = f.read()

    assert "docs/gcp-deployment.md" in readme_content, "README must link to docs/gcp-deployment.md"
    assert "docs/cloudflare-setup.md" in readme_content, "README must link to docs/cloudflare-setup.md"


def test_relative_markdown_links_validity():
    """Verify local relative links in doc files point to existing files."""
    link_pattern = re.compile(r'\[([^\]]+)\]\(([^)]+)\)')

    for doc in DOC_FILES:
        if not os.path.exists(doc):
            continue
        doc_dir = os.path.dirname(doc)
        with open(doc, "r", encoding="utf-8") as f:
            content = f.read()

        for match in link_pattern.finditer(content):
            url = match.group(2).strip()
            # Skip external web URLs, anchors, mailto, etc.
            if url.startswith(("http://", "https://", "#", "mailto:")):
                continue
            # Remove optional anchor in link, e.g. path/to/file.md#section
            clean_url = url.split("#")[0]
            if not clean_url:
                continue
            target_path = os.path.normpath(os.path.join(doc_dir, clean_url))
            assert os.path.exists(target_path), f"Broken relative link in {doc}: '{url}' -> '{target_path}'"
