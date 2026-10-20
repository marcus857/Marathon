from __future__ import annotations

import asyncio
import json

import httpx
import pytest

import app.main as main
import app.providers as providers
from app.auth import InvalidIdentityToken
from app.contracts import GeneratedReview, ReviewClaimCode, ReviewItem
from app.main import app, provider_settings, service_settings
from app.providers import ProviderKind, ProviderSettings, ProviderUnavailableError
from app.settings import AuthMode, ServiceSettings


@pytest.mark.asyncio
async def test_api_refuses_requests_until_auth_is_configured(complete_request) -> None:
    service_settings.cache_clear()
    provider_settings.cache_clear()
    payload = json.loads(complete_request.model_dump_json())

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.post("/v1/weekly-reviews", json=payload)

    assert response.status_code == 503
    assert "authentication is not configured" in response.json()["detail"]


def grounded_review():
    item = ReviewItem(
        claim_code=ReviewClaimCode.MILEAGE_BELOW_PLAN,
        text="Recorded mileage is below the planned amount.",
        evidence_ids=["m.current.actual_miles", "m.current.planned_miles"],
    )
    return GeneratedReview(headline=item, items=[], next_focus=item)


class SyntheticProvider:
    def __init__(self, responses=None):
        self.responses = list(responses or [grounded_review()])
        self.calls = []

    async def generate(self, payload, *, repair_reason=None):
        self.calls.append((payload, repair_reason))
        result = self.responses.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


@pytest.fixture
async def api_client(monkeypatch):
    settings = ServiceSettings(
        _env_file=None,
        environment="development",
        auth_mode=AuthMode.DEVELOPMENT_TOKEN,
        development_token="synthetic-test-token",
    )
    app.dependency_overrides[service_settings] = lambda: settings
    monkeypatch.setattr(main, "service_settings", lambda: settings)
    main.request_limiter.cache_clear()
    selected = ProviderSettings(_env_file=None, provider=ProviderKind.AZURE)
    monkeypatch.setattr(main, "provider_settings", lambda: selected)
    provider = SyntheticProvider()
    monkeypatch.setattr(main, "make_provider", lambda _: provider)
    transport = httpx.ASGITransport(app=app)
    try:
        async with httpx.AsyncClient(
            transport=transport,
            base_url="http://test",
            headers={
                "Authorization": "Bearer synthetic-test-token",
                "X-Weekly-Review-Provider": "azure",
            },
        ) as client:
            yield client, settings, provider
    finally:
        app.dependency_overrides.clear()
        main.request_limiter.cache_clear()


async def test_api_returns_grounded_synthetic_review_without_identity(api_client, complete_request):
    client, _, provider = api_client
    response = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["status"] == "complete"
    assert not response.json()["fallback_used"]
    assert len(provider.calls) == 1
    sent = json.dumps(provider.calls)
    assert "synthetic-test-token" not in sent
    assert "local-synthetic-development" not in sent
    assert "workouts" not in provider.calls[0][0]


@pytest.mark.parametrize("header", [None, "", "openai", "chatgpt", "disabled", "Azure", "azure, openai"])
async def test_api_rejects_missing_or_mismatched_provider_before_processing(
    api_client, complete_request, monkeypatch, header
):
    client, _, provider = api_client
    if header is None:
        del client.headers["X-Weekly-Review-Provider"]
    else:
        client.headers["X-Weekly-Review-Provider"] = header
    monkeypatch.setattr(main, "derive_metrics", lambda _: pytest.fail("No processing without provider consent"))
    monkeypatch.setattr(main, "make_provider", lambda _: pytest.fail("No adapter without provider consent"))
    # Even a metrics-only request must not mask stale provider consent.
    payload = complete_request.model_dump(mode="json")
    payload["data_freshness"]["healthkit_sync_state"] = "unknown"
    response = await client.post("/v1/weekly-reviews", json=payload)
    assert response.status_code == 409
    assert response.headers["cache-control"] == "no-store"
    assert provider.calls == []


async def test_api_rejects_duplicate_provider_headers(api_client, complete_request):
    client, _, provider = api_client
    response = await client.post(
        "/v1/weekly-reviews",
        json=complete_request.model_dump(mode="json"),
        headers=[("X-Weekly-Review-Provider", "azure"), ("X-Weekly-Review-Provider", "azure")],
    )
    assert response.status_code == 409
    assert provider.calls == []


async def test_api_accepts_matching_openai_consent(api_client, complete_request, monkeypatch):
    client, _, provider = api_client
    selected = ProviderSettings(_env_file=None, provider=ProviderKind.OPENAI)
    monkeypatch.setattr(main, "provider_settings", lambda: selected)
    response = await client.post(
        "/v1/weekly-reviews", json=complete_request.model_dump(mode="json"),
        headers={"X-Weekly-Review-Provider": "openai"},
    )
    assert response.status_code == 200
    assert not response.json()["fallback_used"]
    assert len(provider.calls) == 1


async def test_api_disabled_provider_never_constructs_an_adapter(api_client, complete_request, monkeypatch):
    client, _, provider = api_client
    monkeypatch.setattr(main, "provider_settings", lambda: ProviderSettings(_env_file=None))
    monkeypatch.setattr(main, "make_provider", lambda _: pytest.fail("Provider is disabled"))
    response = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
    assert response.status_code == 503
    assert provider.calls == []
    health = await client.get("/health")
    assert health.json() == {
        "status": "ok", "provider_configured": False, "authentication_mode": "development_token"
    }


async def test_invalid_provider_configuration_is_sanitized(api_client, complete_request, monkeypatch):
    client, _, provider = api_client
    provider_settings.cache_clear()
    monkeypatch.setenv("WEEKLY_REVIEW_PROVIDER", "private-invalid-config-value")
    monkeypatch.setattr(main, "provider_settings", provider_settings)
    try:
        response = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
        assert response.status_code == 503
        assert "private-invalid-config-value" not in response.text
        assert provider.calls == []
        health = await client.get("/health")
        assert not health.json()["provider_configured"]
        assert "private-invalid-config-value" not in health.text
        with pytest.raises(ProviderUnavailableError, match="configuration is invalid") as error:
            async with main.lifespan(app):
                pytest.fail("Unknown provider must not start")
        assert error.value.__cause__ is None
        assert "private-invalid-config-value" not in str(error.value)
    finally:
        provider_settings.cache_clear()


@pytest.mark.parametrize("kind", [ProviderKind.AZURE, ProviderKind.OPENAI])
async def test_missing_selected_credentials_returns_metrics_without_switching(
    api_client, complete_request, monkeypatch, kind
):
    client, _, _ = api_client
    selected = ProviderSettings(_env_file=None, provider=kind)
    monkeypatch.setattr(main, "provider_settings", lambda: selected)
    monkeypatch.setattr(main, "make_provider", providers.make_provider)
    # The opposite provider is configured. It must never become a fallback.
    if kind is ProviderKind.AZURE:
        monkeypatch.setenv("OPENAI_API_KEY", "synthetic-unused-key")
        monkeypatch.setenv("OPENAI_MODEL", "synthetic-unused-model")
    else:
        monkeypatch.setenv("AZURE_OPENAI_API_KEY", "synthetic-unused-key")
        monkeypatch.setenv("AZURE_OPENAI_DEPLOYMENT", "synthetic-unused-deployment")
        monkeypatch.setenv("AZURE_OPENAI_ENDPOINT", "https://unused.openai.azure.com")
    monkeypatch.setattr(providers, "_http_client", lambda: pytest.fail("No selected provider credentials"))
    response = await client.post(
        "/v1/weekly-reviews", json=complete_request.model_dump(mode="json"),
        headers={"X-Weekly-Review-Provider": kind.value},
    )
    assert response.status_code == 200
    assert response.json()["status"] == "unavailable"
    assert response.json()["fallback_used"]
    assert response.json()["metrics"]
    assert "provider_unavailable" in response.json()["data_quality_codes"]
    assert not (await client.get("/health")).json()["provider_configured"]


async def test_api_skips_provider_when_import_is_incomplete(api_client, complete_request):
    client, _, provider = api_client
    payload = complete_request.model_dump(mode="json")
    payload["data_freshness"]["healthkit_sync_state"] = "unknown"
    response = await client.post("/v1/weekly-reviews", json=payload)
    assert response.status_code == 200
    assert response.json()["status"] == "insufficient_data"
    assert response.json()["fallback_used"]
    assert provider.calls == []


async def test_api_validation_errors_never_echo_private_input(api_client, complete_request):
    client, _, provider = api_client
    payload = complete_request.model_dump(mode="json")
    payload["private_notes"] = "sensitive-user-health-detail"
    response = await client.post("/v1/weekly-reviews", json=payload)
    assert response.status_code == 422
    assert "sensitive-user-health-detail" not in response.text
    assert "private_notes" not in response.text
    assert provider.calls == []


async def test_api_rejects_oversized_json_before_provider(api_client):
    client, settings, provider = api_client
    settings.max_request_bytes = 1_024
    response = await client.post("/v1/weekly-reviews", json={"x": "a" * 2_048})
    assert response.status_code == 413
    assert provider.calls == []


async def test_api_rejects_oversized_chunked_body(api_client):
    client, settings, _ = api_client
    settings.max_request_bytes = 1_024

    async def chunks():
        yield b'{"x":"'
        yield b"a" * 2_048
        yield b'"}'

    response = await client.post(
        "/v1/weekly-reviews", content=chunks(), headers={"Content-Type": "application/json"}
    )
    assert response.status_code == 413


async def test_api_requires_json_and_does_not_allow_compressed_input(api_client):
    client, _, _ = api_client
    response = await client.post("/v1/weekly-reviews", content="not-json")
    assert response.status_code == 415
    response = await client.post(
        "/v1/weekly-reviews", json={}, headers={"Content-Encoding": "gzip"}
    )
    assert response.status_code == 415


async def test_api_limits_authenticated_subject_requests(api_client, complete_request):
    client, settings, provider = api_client
    settings.requests_per_minute = 1
    first = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
    assert first.status_code == 200
    second = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
    assert second.status_code == 429
    assert 1 <= int(second.headers["retry-after"]) <= 60
    assert len(provider.calls) == 1


async def test_api_invalid_bearer_token_never_calls_provider(api_client, complete_request):
    client, _, provider = api_client
    response = await client.post(
        "/v1/weekly-reviews",
        json=complete_request.model_dump(mode="json"),
        headers={"Authorization": "Bearer invalid"},
    )
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    assert provider.calls == []


async def test_apple_api_rejects_unverified_identity(api_client, complete_request, monkeypatch):
    client, settings, provider = api_client
    settings.auth_mode = AuthMode.APPLE
    settings.apple_audience = "Marcus.Marathon"

    class InvalidVerifier:
        async def verify(self, token):
            raise InvalidIdentityToken("Never disclose " + token)

    monkeypatch.setattr(main, "apple_identity_verifier", lambda: InvalidVerifier())
    response = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
    assert response.status_code == 401
    assert "synthetic-test-token" not in response.text
    assert provider.calls == []


async def test_apple_authorization_has_a_total_deadline(api_client, complete_request, monkeypatch):
    client, settings, provider = api_client
    settings.auth_mode = AuthMode.APPLE
    settings.apple_audience = "Marcus.Marathon"
    cancelled = asyncio.Event()

    class StalledVerifier:
        async def verify(self, token):
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

    monkeypatch.setattr(main, "apple_identity_verifier", lambda: StalledVerifier())
    monkeypatch.setattr(main, "MAX_APPLE_AUTH_SECONDS", 0.01)
    async with asyncio.timeout(1):
        response = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
    assert response.status_code == 503
    assert "synthetic-test-token" not in response.text
    assert cancelled.is_set()
    assert provider.calls == []


async def test_api_attempts_one_repair_then_falls_back(api_client, complete_request):
    client, _, provider = api_client
    rejected = grounded_review()
    rejected.headline.text = "The private model response invents 999 miles."
    provider.responses = [rejected, rejected]
    response = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
    assert response.status_code == 200
    assert response.json()["status"] == "unavailable"
    assert response.json()["fallback_used"]
    assert "provider_response_rejected" in response.json()["data_quality_codes"]
    assert "private model response" not in response.text
    assert len(provider.calls) == 2
    assert "private model response" not in provider.calls[1][1]


async def test_api_accepts_grounded_repair(api_client, complete_request):
    client, _, provider = api_client
    rejected = grounded_review()
    rejected.headline.text = "Recorded mileage is 999 miles."
    provider.responses = [rejected, grounded_review()]
    response = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
    assert response.status_code == 200
    assert not response.json()["fallback_used"]
    assert len(provider.calls) == 2


async def test_api_sanitizes_provider_unavailability(api_client, complete_request):
    client, _, provider = api_client
    provider.responses = [ProviderUnavailableError("private-provider-detail")]
    response = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
    assert response.status_code == 200
    assert response.json()["status"] == "unavailable"
    assert "private-provider-detail" not in response.text


async def test_api_provider_configuration_failure_returns_metrics(api_client, complete_request, monkeypatch):
    client, _, _ = api_client

    def invalid_configuration(_):
        raise ProviderUnavailableError("private-endpoint-and-credential-detail")

    monkeypatch.setattr(main, "make_provider", invalid_configuration)
    response = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
    assert response.status_code == 200
    assert response.json()["fallback_used"]
    assert response.json()["metrics"]
    assert "provider_unavailable" in response.json()["data_quality_codes"]
    assert "private-endpoint-and-credential-detail" not in response.text


@pytest.mark.parametrize("during_repair", [False, True])
async def test_api_deadline_cancels_generation_or_repair(api_client, complete_request, monkeypatch, during_repair):
    client, _, _ = api_client
    cancelled = asyncio.Event()
    calls = 0

    class StalledProvider:
        async def generate(self, payload, *, repair_reason=None):
            nonlocal calls
            calls += 1
            if during_repair and calls == 1:
                rejected = grounded_review()
                rejected.headline.text = "Invented 999 miles."
                return rejected
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

    monkeypatch.setattr(main, "make_provider", lambda _: StalledProvider())
    monkeypatch.setattr(main, "MAX_REVIEW_SECONDS", 0.01)
    async with asyncio.timeout(1):
        response = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
    assert response.status_code == 200
    assert response.json()["status"] == "unavailable"
    assert response.json()["fallback_used"]
    assert response.json()["metrics"]
    assert cancelled.is_set()
    assert calls == (2 if during_repair else 1)


async def test_api_caller_cancellation_propagates_to_provider(api_client, complete_request, monkeypatch):
    client, _, _ = api_client
    started = asyncio.Event()
    cancelled = asyncio.Event()

    class CancellableProvider:
        async def generate(self, payload, *, repair_reason=None):
            started.set()
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

    monkeypatch.setattr(main, "make_provider", lambda _: CancellableProvider())
    task = asyncio.create_task(client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json")))
    try:
        async with asyncio.timeout(1):
            await started.wait()
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
        assert cancelled.is_set()
    finally:
        task.cancel()


async def test_api_provider_failure_during_repair_does_not_try_a_third_time(api_client, complete_request):
    client, _, provider = api_client
    rejected = grounded_review()
    rejected.headline.text = "Invented 999 miles."
    provider.responses = [rejected, ProviderUnavailableError("private-model-error")]
    response = await client.post("/v1/weekly-reviews", json=complete_request.model_dump(mode="json"))
    assert response.status_code == 200
    assert response.json()["fallback_used"]
    assert len(provider.calls) == 2
    assert "private-model-error" not in response.text


@pytest.mark.parametrize("mode", ["success", "outage", "refusal", "incomplete"])
@pytest.mark.parametrize("kind", [ProviderKind.AZURE, ProviderKind.OPENAI])
async def test_api_through_real_sdk_with_mocked_provider_http(api_client, complete_request, monkeypatch, mode, kind):
    """Exercise API -> metrics -> SDK -> validation without external networking."""
    client, _, _ = api_client
    requests = []

    def provider_response(request):
        requests.append(request)
        expected_url = (
            "https://marathon-synthetic-test.openai.azure.com/openai/v1/responses"
            if kind is ProviderKind.AZURE else "https://api.openai.com/v1/responses"
        )
        assert str(request.url) == expected_url
        assert request.headers["authorization"] == "Bearer synthetic-provider-key-not-real"
        sent = json.loads(request.content)
        assert sent["store"] is False
        assert sent["background"] is False
        assert sent["max_output_tokens"] == 1_500
        assert sent["text"]["format"]["strict"] is True
        metrics_payload = json.loads(sent["input"])
        assert "workouts" not in metrics_payload
        assert "synthetic-test-token" not in request.content.decode()
        assert "local-synthetic-development" not in request.content.decode()
        if mode == "outage":
            return httpx.Response(503, json={"error": {"message": "private-provider-error", "type": "server_error"}})
        content = [{"type": "output_text", "text": grounded_review().model_dump_json(), "annotations": []}]
        if mode == "refusal":
            content = [{"type": "refusal", "refusal": "private-refusal-details"}]
        return httpx.Response(200, json={
            "status": "incomplete" if mode == "incomplete" else "completed",
            "error": None,
            "incomplete_details": {"reason": "max_output_tokens"} if mode == "incomplete" else None,
            "output": [{"type": "message", "status": "completed", "role": "assistant", "content": content}],
        })

    monkeypatch.setattr(providers, "_http_client", lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(provider_response), follow_redirects=False, trust_env=False,
        event_hooks={"response": [providers._reject_http_error]},
    ))
    selected = ProviderSettings(_env_file=None, provider=kind)
    monkeypatch.setenv("AZURE_OPENAI_ENDPOINT", "https://marathon-synthetic-test.openai.azure.com")
    monkeypatch.setenv("AZURE_OPENAI_DEPLOYMENT", "synthetic-deployment")
    monkeypatch.setenv("AZURE_OPENAI_API_KEY", "synthetic-provider-key-not-real")
    monkeypatch.setenv("OPENAI_MODEL", "synthetic-model")
    monkeypatch.setenv("OPENAI_API_KEY", "synthetic-provider-key-not-real")
    monkeypatch.setattr(main, "provider_settings", lambda: selected)
    monkeypatch.setattr(main, "make_provider", providers.make_provider)
    response = await client.post(
        "/v1/weekly-reviews", json=complete_request.model_dump(mode="json"),
        headers={"X-Weekly-Review-Provider": kind.value},
    )
    assert response.status_code == 200
    assert response.json()["metrics"]
    assert response.json()["fallback_used"] is (mode != "success")
    assert response.json()["status"] == ("complete" if mode == "success" else "unavailable")
    assert "private-provider-error" not in response.text
    assert "private-refusal-details" not in response.text
    assert len(requests) == 1  # No SDK retry or repair of transport/refusal failures.
