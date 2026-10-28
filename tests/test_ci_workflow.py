# tests/test_ci_workflow.py
import os
import yaml
import pytest

WORKFLOW_PATH = ".github/workflows/ci.yml"

@pytest.fixture
def workflow_data():
    assert os.path.exists(WORKFLOW_PATH), f"{WORKFLOW_PATH} must exist"
    with open(WORKFLOW_PATH, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    assert isinstance(data, dict), "Workflow YAML must parse into a dict"
    return data

def test_ci_workflow_valid(workflow_data):
    """Test that the CI workflow exists, has valid YAML, and has basic triggers and jobs."""
    # YAML parser turns unquoted 'on:' into boolean True in older pyyaml versions, or 'on'
    triggers = workflow_data.get("on") or workflow_data.get(True)
    assert triggers is not None, "Workflow must define 'on' triggers"
    
    if isinstance(triggers, dict):
        assert "push" in triggers, "Workflow must trigger on push"
        assert "pull_request" in triggers, "Workflow must trigger on pull_request"
    elif isinstance(triggers, list):
        assert "push" in triggers
        assert "pull_request" in triggers

    jobs = workflow_data.get("jobs", {})
    assert "test" in jobs, "Workflow jobs must contain 'test'"

def test_ci_workflow_runner(workflow_data):
    """Test that the test job runs on ubuntu-latest."""
    jobs = workflow_data.get("jobs", {})
    test_job = jobs.get("test", {})
    assert test_job.get("runs-on") == "ubuntu-latest", "Job must run on ubuntu-latest"

def test_ci_workflow_steps(workflow_data):
    """Test that required steps are present: checkout, python, shell linting, docker compose config, pytest."""
    jobs = workflow_data.get("jobs", {})
    test_job = jobs.get("test", {})
    steps = test_job.get("steps", [])
    assert len(steps) > 0, "test job must contain steps"

    step_uses = [step.get("uses", "") for step in steps]
    step_runs = [step.get("run", "") for step in steps]
    all_runs_text = "\n".join(step_runs)

    # 1. Checkout step
    assert any("actions/checkout" in use for use in step_uses), "Must use actions/checkout"

    # 2. Setup Python step
    assert any("actions/setup-python" in use for use in step_uses), "Must use actions/setup-python"
    python_step = next(s for s in steps if "actions/setup-python" in s.get("uses", ""))
    python_version = str(python_step.get("with", {}).get("python-version", ""))
    assert "3." in python_version or "3.12" in python_version or "3.x" in python_version, "Python version must be 3.x or 3.12"

    # 3. Dependencies installation step
    assert "pytest" in all_runs_text and "pyyaml" in all_runs_text, "Must install pytest and pyyaml"

    # 4. Shell script syntax verification (bash -n)
    assert "bash -n" in all_runs_text, "Must verify shell scripts with bash -n"
    assert "scripts" in all_runs_text, "Must target scripts/ directory for shell verification"

    # 5. Docker compose config check
    assert "docker compose config" in all_runs_text, "Must run docker compose config"

    # 6. Pytest run
    assert "pytest" in all_runs_text, "Must run pytest"
    assert "tests" in all_runs_text, "Must run pytest on tests/"
