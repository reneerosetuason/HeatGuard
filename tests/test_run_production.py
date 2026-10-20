"""Tests for the production server's configuration checks."""

import pytest

from run_production import _is_secure_secret


@pytest.mark.parametrize(
    "value",
    [
        "",
        "short",
        "dev-only-change-this-secret",
        "change-me-to-a-random-string",
    ],
)
def test_rejects_weak_secret_keys(value):
    assert _is_secure_secret(value) is False


def test_accepts_long_random_secret_key():
    assert _is_secure_secret("a" * 64) is True
