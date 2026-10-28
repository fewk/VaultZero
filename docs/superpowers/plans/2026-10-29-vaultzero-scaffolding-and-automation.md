# VaultZero: Self-Hosted Vaultwarden on GCP Always Free Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and open-source `VaultZero` — a turnkey, zero-cost ($0.00/month), zero-open-port, pure IPv6-native Vaultwarden deployment on Google Cloud Platform Always Free with Cloudflare Tunnel, Zero Trust WAF/OTP protection, and automated R2 disaster recovery.

**Architecture:** A dual-stack GCP `e2-micro` instance in `us-west1` runs without an external IPv4 address (`--no-address`) to eliminate IP lease fees, utilizing free external IPv6 and Google Cloud IAP for admin SSH. Inbound access is routed entirely through a pure IPv6 Cloudflare Tunnel to local Vaultwarden running in Docker host networking mode with `IP_HEADER=CF-Connecting-IP`, accompanied by `ttionya/vaultwarden-backup` streaming AES-encrypted zero-lock hot backups to Cloudflare R2 on a 30-day retention cycle.

**Tech Stack:** Docker & Docker Compose (`network_mode: "host"`), Vaultwarden (Rust), `ttionya/vaultwarden-backup`, Cloudflare Tunnel (`cloudflared` pure IPv6 QUIC), Cloudflare Zero Trust Access & WAF, Cloudflare R2 (S3 API) via Rclone, Debian 12 (bookworm), nat64.net DNS64/NAT64 translator, Bash automation, Python test harness (pytest/pyyaml).

---

## Global Constraints

- **Absolute $0.00 Cost Guarantee**: Never assign an external IPv4 address (`--no-address`). External IPv6 is $0.00.
- **Zero Inbound Port Exposure**: No public 80/443 ports open in GCP firewall. All ingress traverses `cloudflared`.
- **Administrative Access**: Admin SSH is restricted exclusively to GCP IAP CIDR (`35.235.240.0/20`).
- **Real IP Auditing**: Vaultwarden must explicitly configure `IP_HEADER=CF-Connecting-IP` to prevent 127.0.0.1 lockout loops.
- **Docker Host Networking**: All services in `docker-compose.yml` use `network_mode: "host"` to directly leverage host IPv6 and NAT64 gateway without Docker bridge virtualization lockups.
- **Disaster Recovery RTO**: Restore operations must complete within 3 minutes using standard AES decryption and docker compose up.

---

### Task 1: Project Scaffolding, Git Configuration, and License

**Files:**
- Create: `.gitignore`
- Create: `LICENSE`
- Create: `README.md`
- Test: `tests/test_repo_structure.py`

**Interfaces:**
- Consumes: None (root repo baseline)
- Produces: Base repository structure, Git exclusions, licensing, and comprehensive documentation index.

- [ ] **Step 1: Write test for repo baseline and security exclusions**

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_repo_structure.py -v`
Expected: FAIL with missing `.gitignore`

- [ ] **Step 3: Implement `.gitignore`, `LICENSE`, and `README.md`**

Create `.gitignore` containing all sensitive runtime artifacts (`.env`, `rclone.conf`, `data/`, `*.enc`, `*.zip`, `*.key`, `.cloudflared/`).
Create `LICENSE` (MIT License).
Create `README.md` with:
- Project badge header
- Problem statement ($0 GCP fee trap vs VaultZero solution)
- Mermaid architecture diagram
- Quickstart 3-step guide
- Directory hierarchy breakdown

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_repo_structure.py -k test_sensitive_files_ignored -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add .gitignore LICENSE README.md tests/test_repo_structure.py
git commit -m "chore: scaffold project baseline, gitignore, and initial documentation"
```

---

### Task 2: Docker Compose Orchestration & Configuration Templates

**Files:**
- Create: `docker-compose.yml`
- Create: `.env.example`
- Create: `rclone/rclone.conf.example`
- Test: `tests/test_docker_compose.py`

**Interfaces:**
- Consumes: Docker host networking and environment variables defined in `.env.example`.
- Produces: Validated, production-hardened compose definition for Vaultwarden and `ttionya/vaultwarden-backup`.

- [ ] **Step 1: Write validation test for docker-compose.yml and .env.example**

```python
# tests/test_docker_compose.py
import os
import yaml
import pytest

def test_docker_compose_schema_and_constraints():
    assert os.path.exists("docker-compose.yml")
    with open("docker-compose.yml", "r", encoding="utf-8") as f:
        compose = yaml.safe_load(f)

    services = compose.get("services", {})
    assert "vaultwarden" in services
    assert "backup" in services

    vw = services["vaultwarden"]
    assert vw.get("network_mode") == "host", "Vaultwarden must use host networking for IPv6"
    assert vw.get("restart") == "unless-stopped"
    
    # Verify IP_HEADER
    env = vw.get("environment", [])
    env_dict = {}
    for item in env:
        if "=" in item:
            k, v = item.split("=", 1)
            env_dict[k] = v
    assert env_dict.get("IP_HEADER") == "CF-Connecting-IP", "IP_HEADER must be CF-Connecting-IP"
    assert env_dict.get("SIGNUPS_ALLOWED") == "false"
    assert env_dict.get("ROCKET_PORT") == "8080"

    bk = services["backup"]
    assert bk.get("network_mode") == "host", "Backup must use host networking for IPv6 NAT64"
    assert "vaultwarden" in bk.get("depends_on", [])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_docker_compose.py -v`
Expected: FAIL with missing `docker-compose.yml`

- [ ] **Step 3: Create `docker-compose.yml`, `.env.example`, and `rclone/rclone.conf.example`**

Write `docker-compose.yml` strictly adhering to Section 4.2 of the specification:
- Vaultwarden with `network_mode: "host"`, `ROCKET_PORT=8080`, `IP_HEADER=CF-Connecting-IP`, `LOGIN_RATELIMIT_MAX_BURST=10`, `LOGIN_RATELIMIT_SECONDS=60`, log rotation (`max-size: 10m`, `max-file: 3`).
- `ttionya/vaultwarden-backup:latest` with `network_mode: "host"`, read-only data volume mount `/opt/vaultwarden/data:/vaultwarden/data:ro`, rclone volume mount `/opt/vaultwarden/rclone:/config/rclone`, log rotation (`max-size: 5m`, `max-file: 2`).
- `.env.example` documenting all configuration keys (`DOMAIN`, `ADMIN_TOKEN`, `BACKUP_ZIP_PASS`, `RCLONE_REMOTE_NAME`, `TZ`).
- `rclone/rclone.conf.example` illustrating Cloudflare R2 S3 provider setup.

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_docker_compose.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml .env.example rclone/rclone.conf.example tests/test_docker_compose.py
git commit -m "feat(docker): add host-mode compose orchestration and config templates"
```

---

### Task 3: Cloudflared Pure IPv6 Configuration & Service Automation

**Files:**
- Create: `cloudflared/config.example.yml`
- Create: `scripts/02-setup-cloudflared.sh`
- Test: `tests/test_cloudflared_config.py`

**Interfaces:**
- Consumes: Tunnel credentials JSON generated by Cloudflare Zero Trust.
- Produces: Systemd-managed `cloudflared` service tunneling `vault.yourdomain.com` directly to `127.0.0.1:8080` over IPv6 QUIC.

- [ ] **Step 1: Write test for cloudflared config and script syntax**

```python
# tests/test_cloudflared_config.py
import os
import subprocess
import yaml
import pytest

def test_cloudflared_yaml_config():
    assert os.path.exists("cloudflared/config.example.yml")
    with open("cloudflared/config.example.yml", "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    assert cfg.get("edge-ip-version") == "6" or cfg.get("edge-ip-version") == 6
    assert cfg.get("protocol") == "quic"
    ingress = cfg.get("ingress", [])
    assert any("8080" in item.get("service", "") for item in ingress)
    assert ingress[-1].get("service") == "http_status:404"

def test_setup_cloudflared_script_syntax():
    script = "scripts/02-setup-cloudflared.sh"
    assert os.path.exists(script)
    res = subprocess.run(["bash", "-n", script], capture_output=True, text=True)
    assert res.returncode == 0, f"Bash syntax error in {script}: {res.stderr}"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_cloudflared_config.py -v`
Expected: FAIL with missing configuration and script files

- [ ] **Step 3: Implement `cloudflared/config.example.yml` and `scripts/02-setup-cloudflared.sh`**

Write `cloudflared/config.example.yml` with:
- `edge-ip-version: "6"`
- `protocol: quic`
- `ingress` rules pointing to `http://127.0.0.1:8080` and `http_status:404`.

Write `scripts/02-setup-cloudflared.sh`:
- Auto-detects system architecture (`amd64` vs `arm64`).
- Downloads official `cloudflared` Debian package.
- Sets up `/etc/cloudflared/config.yml` with permissions `0600`.
- Configures systemd unit with auto-restart.

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_cloudflared_config.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add cloudflared/config.example.yml scripts/02-setup-cloudflared.sh tests/test_cloudflared_config.py
git commit -m "feat(tunnel): add cloudflared pure-IPv6 config template and installer"
```

---

### Task 4: VM Bootstrap Script with 1GB Swap & NAT64 Gateway Resolver

**Files:**
- Create: `scripts/01-bootstrap-vm.sh`
- Test: `tests/test_bootstrap_script.py`

**Interfaces:**
- Consumes: Clean Debian 12 minimal environment in GCP Always Free.
- Produces: 1GB active swap, `/etc/resolv.conf` with nat64.net forwarding resolver, Docker engine & Compose plugin, `/opt/vaultwarden` directory tree.

- [ ] **Step 1: Write test for VM bootstrap script structure and safety checks**

```python
# tests/test_bootstrap_script.py
import os
import subprocess
import pytest

def test_bootstrap_script_syntax_and_keywords():
    script = "scripts/01-bootstrap-vm.sh"
    assert os.path.exists(script)
    res = subprocess.run(["bash", "-n", script], capture_output=True, text=True)
    assert res.returncode == 0, f"Bash syntax error: {res.stderr}"

    with open(script, "r", encoding="utf-8") as f:
        content = f.read()

    # Must contain NAT64 DNS resolvers
    assert "2a01:4ff:f0:9876::1" in content
    assert "2a00:1098:2b::1" in content
    # Must setup swapfile of 1GB
    assert "swapfile" in content
    # Must install docker
    assert "docker" in content
    # Must create directory hierarchy
    assert "/opt/vaultwarden" in content
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_bootstrap_script.py -v`
Expected: FAIL with missing `scripts/01-bootstrap-vm.sh`

- [ ] **Step 3: Implement `scripts/01-bootstrap-vm.sh`**

Implement `scripts/01-bootstrap-vm.sh` with `set -euo pipefail`:
- Verifies root privileges (`EUID == 0`).
- Configures DNS64/NAT64 in `/etc/resolv.conf` with `nat64.net` Ashburn (`2a01:4ff:f0:9876::1`), Amsterdam (`2a00:1098:2b::1`), and Cloudflare (`2606:4700:4700::1111`), making the file immutable (`chattr +i` where applicable or systemd-resolved override).
- Validates outbound NAT64 by pinging/curling `api.github.com` via IPv6.
- Idempotently creates `/swapfile` (1024M), enables swapon, sets `vm.swappiness=10`, and persists in `/etc/fstab`.
- Installs prerequisites, imports Docker official GPG key via IPv6/NAT64, and installs `docker-ce` + `docker-compose-plugin`.
- Creates `/opt/vaultwarden/{data,rclone,env}` with appropriate permissions (`0700`).

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_bootstrap_script.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/01-bootstrap-vm.sh tests/test_bootstrap_script.py
git commit -m "feat(bootstrap): add VM initialization script with swap and NAT64 resolver"
```

---

### Task 5: Disaster Recovery & Automated Health Verification Scripts

**Files:**
- Create: `scripts/03-restore-backup.sh`
- Create: `scripts/verify-health.sh`
- Test: `tests/test_utility_scripts.py`

**Interfaces:**
- Consumes: Backup archive `.zip` stored in Cloudflare R2 or local directory, running host services.
- Produces: Restored `/opt/vaultwarden/data` state within 3 minutes; non-zero exit codes if security/networking constraints are violated.

- [ ] **Step 1: Write test for restore and verification scripts**

```python
# tests/test_utility_scripts.py
import os
import subprocess
import pytest

SCRIPTS = [
    "scripts/03-restore-backup.sh",
    "scripts/verify-health.sh",
]

@pytest.mark.parametrize("script", SCRIPTS)
def test_script_syntax(script):
    assert os.path.exists(script)
    res = subprocess.run(["bash", "-n", script], capture_output=True, text=True)
    assert res.returncode == 0, f"Syntax error in {script}: {res.stderr}"

def test_verify_health_contains_safety_audits():
    with open("scripts/verify-health.sh", "r", encoding="utf-8") as f:
        content = f.read()
    # Must check IPv4 absence
    assert "no-address" in content or "external" in content.lower()
    # Must check vaultwarden health
    assert "8080" in content
    # Must check cloudflared
    assert "cloudflared" in content
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_utility_scripts.py -v`
Expected: FAIL with missing scripts

- [ ] **Step 3: Implement `scripts/03-restore-backup.sh` and `scripts/verify-health.sh`**

Write `scripts/03-restore-backup.sh`:
- Accepts path to `.zip` file or fetches latest archive from Rclone remote `r2:vaultwarden-backup`.
- Prompts for or reads `BACKUP_ZIP_PASS`.
- Verifies archive integrity using `unzip -t -P <password>`.
- Gracefully stops `vaultwarden` container.
- Extracts files safely into `/opt/vaultwarden/data`.
- Corrects ownership and permissions (`0700`).
- Restarts containers and verifies `127.0.0.1:8080/alive`.

Write `scripts/verify-health.sh`:
- Checks that no external IPv4 is assigned to local interfaces.
- Checks IPv6 default gateway and NAT64 connectivity (`curl -sS -6 https://api.github.com`).
- Checks if ports 80/443 are NOT open publicly.
- Checks local Vaultwarden HTTP response on `127.0.0.1:8080/alive`.
- Audits Vaultwarden logs for `CF-Connecting-IP` headers.
- Checks `cloudflared` systemd unit status.

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_utility_scripts.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/03-restore-backup.sh scripts/verify-health.sh tests/test_utility_scripts.py
git commit -m "feat(ops): add zero-downtime restore script and health auditor"
```

---

### Task 6: Comprehensive Step-by-Step Deployment Guides

**Files:**
- Create: `docs/gcp-deployment.md`
- Create: `docs/cloudflare-setup.md`
- Modify: `README.md`
- Test: `tests/test_docs_links.py`

**Interfaces:**
- Consumes: Spec requirements for VPC dual-stack, IAP SSH, Cloudflare WAF, and Access policies.
- Produces: Production runbooks with exact copy-paste `gcloud` CLI commands and Cloudflare dashboard clickpaths.

- [ ] **Step 1: Write test for documentation consistency and link integrity**

```python
# tests/test_docs_links.py
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
    assert os.path.exists(doc)
    assert os.path.getsize(doc) > 200

def test_gcp_doc_contains_required_flags():
    with open("docs/gcp-deployment.md", "r", encoding="utf-8") as f:
        content = f.read()
    assert "--no-address" in content, "Must emphasize --no-address to avoid IPv4 billing"
    assert "e2-micro" in content
    assert "us-west1" in content
    assert "35.235.240.0/20" in content, "Must include IAP CIDR"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_docs_links.py -v`
Expected: FAIL with missing documentation files

- [ ] **Step 3: Implement `docs/gcp-deployment.md` and `docs/cloudflare-setup.md`**

Implement `docs/gcp-deployment.md`:
- Detailed `gcloud` CLI commands to create dual-stack VPC, create firewall rule restricting SSH to `35.235.240.0/20`, and provision `e2-micro` VM with `--no-address` and `--stack-type IPV4_IPV6`.
- Detailed GCP Console web UI walkthrough with clear instructions.
- Connecting via `gcloud compute ssh --tunnel-through-iap`.

Implement `docs/cloudflare-setup.md`:
- Step 1: Cloudflare Tunnel creation and token retrieval.
- Step 2: Custom public hostname configuration (`vault.yourdomain.com` -> `http://127.0.0.1:8080`).
- Step 3: Cloudflare WAF Rate Limiting rule for `(http.request.uri.path eq "/identity/connect/token" and http.request.method eq "POST")` with 10 req/min action Block.
- Step 4: Cloudflare Zero Trust Access Application for `/admin*` requiring Email OTP verification.
- Step 5: Cloudflare R2 bucket creation (`vaultwarden-backup`) and S3 credential issuance.

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_docs_links.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add docs/gcp-deployment.md docs/cloudflare-setup.md README.md tests/test_docs_links.py
git commit -m "docs: add comprehensive GCP and Cloudflare step-by-step runbooks"
```

---

### Task 7: GitHub Actions CI Workflow for Linting & Syntax Testing

**Files:**
- Create: `.github/workflows/ci.yml`
- Test: `tests/test_ci_workflow.py`

**Interfaces:**
- Consumes: Test suite in `tests/` and shell scripts in `scripts/`.
- Produces: Automated pull request and commit validation on GitHub.

- [ ] **Step 1: Write test for CI workflow configuration**

```python
# tests/test_ci_workflow.py
import os
import yaml
import pytest

def test_ci_workflow_valid():
    wf_path = ".github/workflows/ci.yml"
    assert os.path.exists(wf_path)
    with open(wf_path, "r", encoding="utf-8") as f:
        wf = yaml.safe_load(f)
    assert "push" in wf.get("on", {}) or "push" in wf.get(True, {})
    jobs = wf.get("jobs", {})
    assert "test" in jobs
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_ci_workflow.py -v`
Expected: FAIL with missing `.github/workflows/ci.yml`

- [ ] **Step 3: Implement `.github/workflows/ci.yml`**

Write GitHub Actions workflow:
- Matrix check on Ubuntu latest.
- Installs Python, dependencies (`pytest`, `pyyaml`).
- Runs `pytest tests/ -v`.
- Runs `bash -n` on all `.sh` scripts.
- Verifies docker-compose syntax.

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_ci_workflow.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml tests/test_ci_workflow.py
git commit -m "ci: add GitHub Actions workflow for linting and regression testing"
```

---

### Task 8: Comprehensive Verification & Remote Push

**Files:**
- Test all repository artifacts against global constraints.
- Run complete test suite: `pytest tests/ -v`

- [ ] **Step 1: Execute full test suite locally**

Run: `python -m pytest tests/ -v`
Expected: All tests PASS with 100% green status.

- [ ] **Step 2: Verify git status and branch cleanliness**

Run: `git status`
Expected: Working tree clean on branch `main`.

- [ ] **Step 3: Push initial release to remote repository**

Run: `git push -u origin main`
Expected: Remote branch `main` updated on `https://github.com/fewk/VaultZero.git`.
