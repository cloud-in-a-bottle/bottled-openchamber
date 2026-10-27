"""Tests for what this package changes on top of upstream OpenChamber.

- Owner SSO: OpenChamber's own login is disabled, so the owner lands in the app with no password prompt.
- In-container gate: nginx refuses any request without the router-stamped X-OpenHost-Is-Owner: true header.
- Storage: HOME is moved under the app data dir, so OpenChamber/OpenCode state persists.
- Secrets: ANTHROPIC_API_KEY is fetched from the secrets service at boot and reaches the OpenCode agent.
"""

import json
import subprocess
import time
from typing import Any

import requests
from openhost_test_harness import OpenhostStack

COLD_START_MARKER = "OpenChamber is starting"


def _logs(stack: OpenhostStack) -> str:
    return f"\n\napp logs:\n{stack.app_logs()[-5000:]}"


def _get_json_when_ready(stack: OpenhostStack, path: str, timeout: float = 180) -> Any:
    """GET an OpenChamber API path as the owner, waiting out the cold start (nginx answers 200 with a placeholder)."""
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        try:
            response = stack.owner_session.get(f"{stack.url}{path}", timeout=30)
            if response.status_code == 200 and COLD_START_MARKER not in response.text:
                return response.json()
            last = f"{response.status_code}: {response.text[:300]}"
        except (requests.ConnectionError, ValueError) as e:
            last = repr(e)
        time.sleep(2)
    raise AssertionError(f"GET {path} never returned OpenChamber JSON; last: {last}{_logs(stack)}")


def test_owner_lands_in_app_without_login(stack: OpenhostStack) -> None:
    session = _get_json_when_ready(stack, "/auth/session")
    assert session.get("authenticated") is True, f"owner is not authenticated in OpenChamber: {session}"
    page = stack.owner_session.get(f"{stack.url}/", headers={"Accept": "text/html"}, timeout=30)
    assert page.status_code == 200 and COLD_START_MARKER not in page.text, (
        f"GET / did not serve the OpenChamber UI: {page.status_code}: {page.text[:300]}"
    )


def test_container_refuses_requests_without_owner_header(stack: OpenhostStack) -> None:
    _get_json_when_ready(stack, "/auth/session")
    # stack.app_url bypasses the router, so nothing stamps the owner header.
    anonymous = requests.get(f"{stack.app_url}/api/fs/home", timeout=30)
    assert anonymous.status_code == 403, (
        f"expected 403 without the owner header: {anonymous.status_code}: {anonymous.text[:300]}"
    )
    not_owner = requests.get(f"{stack.app_url}/api/fs/home", headers={"X-OpenHost-Is-Owner": "false"}, timeout=30)
    assert not_owner.status_code == 403, (
        f"expected 403 for a non-owner: {not_owner.status_code}: {not_owner.text[:300]}"
    )
    owner = requests.get(f"{stack.app_url}/api/fs/home", headers={"X-OpenHost-Is-Owner": "true"}, timeout=30)
    assert owner.status_code == 200, f"owner header should be let through: {owner.status_code}: {owner.text[:300]}"


def test_settings_are_stored_under_app_data(stack: OpenhostStack) -> None:
    _get_json_when_ready(stack, "/auth/session")
    theme = f"harness-theme-{int(time.time())}"
    response = stack.owner_session.put(f"{stack.url}/api/config/settings", json={"themeId": theme}, timeout=30)
    assert response.status_code == 200, f"saving settings failed: {response.status_code}: {response.text[:300]}"
    settings_file = stack.data_dir / "home" / ".config" / "openchamber" / "settings.json"
    # The file is owned by the container's app user, so read it inside podman's user namespace.
    result = subprocess.run(["podman", "unshare", "cat", str(settings_file)], capture_output=True, text=True)
    assert result.returncode == 0, f"{settings_file} not found under app data: {result.stderr}{_logs(stack)}"
    assert json.loads(result.stdout).get("themeId") == theme, (
        f"setting not persisted to {settings_file}: {result.stdout[:500]}"
    )


def _connected_providers(providers: Any) -> list[str]:
    """Provider ids OpenCode has credentials for. OpenCode 2 lists only those, as {"data": [{"id": ...}]}."""
    if not isinstance(providers, dict):
        return []
    return [p.get("id") for p in providers.get("data", []) if isinstance(p, dict)]


def test_anthropic_key_from_secrets_reaches_agent(stack: OpenhostStack) -> None:
    deadline = time.monotonic() + 180
    providers: Any = None
    while time.monotonic() < deadline:
        providers = _get_json_when_ready(stack, "/api/provider")
        if "anthropic" in _connected_providers(providers):
            return
        time.sleep(3)
    raise AssertionError(f"anthropic not connected in OpenCode (providers={providers}){_logs(stack)}")
