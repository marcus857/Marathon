from __future__ import annotations

import json
import os
import subprocess
import sys

from app.contracts import ReviewStatus, WeeklyReviewResponse
from app.demo import demo_result, main, synthetic_request
from app.metrics import derive_metrics


def test_demo_is_synthetic_and_explicitly_not_ai():
    result = demo_result()
    assert result["demo"]["synthetic_data"] is True
    assert result["demo"]["ai_generated"] is False
    assert result["demo"]["network_used"] is False
    assert "not AI-generated" in result["demo"]["notice"]
    response = WeeklyReviewResponse.model_validate(result["response"])
    assert response.status is ReviewStatus.INSUFFICIENT_DATA
    assert response.fallback_used
    assert "healthkit_unknown" in response.data_quality_codes
    assert not derive_metrics(synthetic_request()).can_call_model


def test_demo_metrics_match_fixed_sample():
    metrics = {metric["id"]: metric for metric in demo_result()["response"]["metrics"]}
    assert metrics["m.current.actual_miles"]["value"] == 7.0
    assert metrics["m.current.actual_runs"]["value"] == 2
    assert metrics["m.current.duration_seconds"]["value"] == 4_200
    assert metrics["m.current.weighted_pace_sec_per_mile"]["value"] == 600.0
    assert metrics["m.current.planned_miles"]["value"] == 10.0
    assert metrics["m.current.required_runs"]["value"] == 3


def test_demo_citations_resolve_to_metrics_and_synthetic_workouts():
    response = demo_result()["response"]
    metric_ids = {metric["id"] for metric in response["metrics"]}
    evidence_ids = {workout.evidence_id for workout in synthetic_request().workouts}
    review = response["review"]
    for item in [review["headline"], *review["items"], review["next_focus"]]:
        assert item["evidence_ids"]
        assert set(item["evidence_ids"]) <= metric_ids
    for metric in response["metrics"]:
        assert set(metric["source_evidence_ids"]) <= evidence_ids


def test_demo_is_repeatable_and_ignores_service_environment(monkeypatch):
    baseline = demo_result()
    sentinels = {
        "WEEKLY_REVIEW_PROVIDER": "deliberately-invalid-provider",
        "WEEKLY_REVIEW_AUTH_MODE": "deliberately-invalid-auth",
        "OPENAI_API_KEY": "synthetic-unused-sentinel",
        "AZURE_OPENAI_API_KEY": "synthetic-unused-sentinel",
    }
    for name, value in sentinels.items():
        monkeypatch.setenv(name, value)
    assert demo_result() == baseline == demo_result()
    assert {name: os.environ[name] for name in sentinels} == sentinels
    assert "synthetic-unused-sentinel" not in json.dumps(baseline)


def test_demo_main_prints_only_stable_json(capsys):
    main()
    first = capsys.readouterr()
    main()
    second = capsys.readouterr()
    assert first.out == second.out
    assert first.err == second.err == ""
    assert json.loads(first.out) == demo_result()


def test_demo_cli_runs_outside_repository_without_fixture_files():
    # The suite's autouse fixture moves to an empty directory. This exercises
    # the installed package rather than a relative tests/fixtures dependency.
    completed = subprocess.run(
        [sys.executable, "-m", "app.demo"],
        check=True, capture_output=True, text=True, timeout=10,
    )
    assert completed.stderr == ""
    assert json.loads(completed.stdout) == demo_result()


def test_demo_entrypoint_never_imports_service_or_provider_code_or_uses_network():
    # Fresh interpreter: unrelated API tests may already have imported these
    # modules in pytest. Forbid them before loading the demo's module entrypoint.
    script = """
import importlib.abc
import runpy
import socket
import sys

class BlockServiceImports(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        forbidden = ('app.providers', 'app.auth', 'app.settings', 'app.main',
                     'httpx', 'openai', 'pydantic_settings')
        if any(fullname == name or fullname.startswith(name + '.') for name in forbidden):
            raise AssertionError('The demo must not import service/provider dependencies')
        return None

def no_network(*args, **kwargs):
    raise AssertionError('The demo must not open network connections')

sys.meta_path.insert(0, BlockServiceImports())
socket.socket.connect = no_network
socket.socket.connect_ex = no_network
socket.create_connection = no_network
socket.getaddrinfo = no_network
runpy.run_module('app.demo', run_name='__main__')
"""
    completed = subprocess.run(
        [sys.executable, "-c", script],
        check=True, capture_output=True, text=True, timeout=10,
    )
    assert completed.stderr == ""
    assert json.loads(completed.stdout) == demo_result()
