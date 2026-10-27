from collections.abc import Iterator

import pytest
from openhost_test_harness import OpenhostStack

# The secrets provider the app fetches ANTHROPIC_API_KEY / GITHUB_TOKEN from at boot, pinned to a commit.
SECRETS_REPO_URL = "https://github.com/cloud-in-a-bottle/secrets@e49eac5a0ceb569e2eb19ccc499fb65343d371ce"
FAKE_ANTHROPIC_API_KEY = "sk-ant-harness-not-a-real-key"


def _seed_secrets(stack: OpenhostStack) -> None:
    """Like an owner preparing the zone: install the secrets app and store the API key before installing OpenChamber."""
    stack.deploy_app(SECRETS_REPO_URL, timeout=600)
    response = stack.owner_session.post(
        f"{stack.url_for('secrets')}/api/secrets",
        json={"key": "ANTHROPIC_API_KEY", "value": FAKE_ANTHROPIC_API_KEY, "description": "test"},
        timeout=30,
    )
    assert response.status_code in (200, 201), (
        f"storing the secret failed: {response.status_code}: {response.text[:300]}"
    )


@pytest.fixture(scope="session")
def stack() -> Iterator[OpenhostStack]:
    """Builds the Dockerfile and deploys the app through the real router; returns once the app is running."""
    with OpenhostStack(pre_deploy=_seed_secrets) as s:
        yield s
