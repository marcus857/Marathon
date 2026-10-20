from __future__ import annotations

import json
import os
from pathlib import Path

import httpx
import pytest

from app.contracts import WeeklyReviewRequest


@pytest.fixture(autouse=True)
def offline_test_environment(monkeypatch, tmp_path):
    """Tests never load developer credentials or contact a real HTTP service."""
    for name in tuple(os.environ):
        if name.startswith(("OPENAI_", "AZURE_OPENAI_", "WEEKLY_REVIEW_")):
            monkeypatch.delenv(name)
    monkeypatch.chdir(tmp_path)  # Prevent BaseSettings from reading a real .env.

    def reject_http(*_args, **_kwargs):
        pytest.fail("Live HTTP is forbidden in synthetic weekly-review tests")

    async def reject_async_http(*_args, **_kwargs):
        pytest.fail("Live HTTP is forbidden in synthetic weekly-review tests")

    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", reject_http)
    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", reject_async_http)


@pytest.fixture
def complete_request() -> WeeklyReviewRequest:
    fixture = Path(__file__).parent / "fixtures" / "complete_week.json"
    return WeeklyReviewRequest.model_validate(json.loads(fixture.read_text()))
