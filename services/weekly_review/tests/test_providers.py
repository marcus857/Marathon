from __future__ import annotations

import asyncio
import copy
import json
import traceback

import httpx
import pytest

import app.providers as providers
from app.providers import (
    AzureOpenAIResponsesProvider,
    AzureOpenAISettings,
    OpenAIResponsesProvider,
    OpenAISettings,
    ProviderKind,
    ProviderSettings,
    ProviderUnavailableError,
    UnconfiguredProvider,
    make_provider,
    strict_review_schema,
)


def settings(endpoint="https://synthetic-resource.openai.azure.com"):
    return AzureOpenAISettings(
        _env_file=None,
        AZURE_OPENAI_ENDPOINT=endpoint,
        AZURE_OPENAI_DEPLOYMENT="synthetic-deployment",
        AZURE_OPENAI_API_KEY="synthetic-key-not-a-credential",
    )


def direct_openai_settings():
    return OpenAISettings(
        _env_file=None,
        OPENAI_MODEL="synthetic-model-explicitly-configured",
        OPENAI_API_KEY="synthetic-key-not-a-credential",
    )


@pytest.fixture(params=["azure", "openai"])
def configured_provider(request):
    if request.param == "azure":
        return AzureOpenAIResponsesProvider(settings())
    return OpenAIResponsesProvider(direct_openai_settings())


def review_json():
    item = {
        "claim_code": "mileage_below_plan",
        "text": "Recorded mileage is below the planned amount.",
        "evidence_ids": ["m.current.actual_miles", "m.current.planned_miles"],
    }
    return {"headline": item, "items": [], "next_focus": copy.deepcopy(item)}


def response_json():
    return {
        "id": "resp-synthetic",
        "status": "completed",
        "error": None,
        "incomplete_details": None,
        "output": [{
            "id": "msg-synthetic",
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": json.dumps(review_json())}],
        }],
    }


def mock_http(monkeypatch, handler):
    clients = []

    def factory():
        client = httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            follow_redirects=False,
            trust_env=False,
            event_hooks={"response": [providers._reject_http_error]},
        )
        clients.append(client)
        return client

    monkeypatch.setattr(providers, "_http_client", factory)
    return clients


@pytest.mark.parametrize(
    ("endpoint", "expected"),
    [
        ("https://sample.openai.azure.com", "https://sample.openai.azure.com/openai/v1/"),
        ("https://sample.openai.azure.com/", "https://sample.openai.azure.com/openai/v1/"),
        ("https://sample.openai.azure.com/openai/v1", "https://sample.openai.azure.com/openai/v1/"),
        ("https://sample.openai.azure.com:443/openai/v1/", "https://sample.openai.azure.com/openai/v1/"),
        ("https://sample.services.ai.azure.com", "https://sample.services.ai.azure.com/openai/v1/"),
    ],
)
def test_azure_endpoint_is_canonical_https_resource(endpoint, expected):
    assert settings(endpoint).base_url == expected


@pytest.mark.parametrize(
    "endpoint",
    [
        "http://sample.openai.azure.com",
        "https://untrusted.invalid",
        "https://sample.openai.azure.com.untrusted.invalid",
        "https://sample.openai.azure.com@untrusted.invalid",
        "https://name:secret@sample.openai.azure.com",
        "https://sample.openai.azure.com:444",
        "https://sample.openai.azure.com/openai/v1/responses",
        "https://sample.openai.azure.com/../openai/v1",
        "https://sample.openai.azure.com?secret=sensitive-value",
        "https://sample.openai.azure.com?",
        "https://sample.openai.azure.com#secret",
        "https://sample.openai.azure.com\\untrusted.invalid",
        "https://sample.openai.azure.com\n",
        "https://sample.openai.azure.com:invalid",
        "https://127.0.0.1",
        "https://nested.sample.openai.azure.com",
        "https://sample.openai.azure.com/openai/v1//",
    ],
)
def test_invalid_endpoint_never_constructs_http_client(monkeypatch, endpoint):
    monkeypatch.setattr(providers, "_http_client", lambda: pytest.fail("No HTTP client permitted"))
    with pytest.raises(ProviderUnavailableError) as error:
        AzureOpenAIResponsesProvider(settings(endpoint))
    assert "sensitive-value" not in str(error.value)
    assert "secret@" not in str(error.value)


def test_provider_schema_requires_all_properties_and_omits_unsupported_constraints():
    schema = strict_review_schema()
    assert set(schema["required"]) == {"headline", "items", "next_focus"}

    def check(node):
        if isinstance(node, dict):
            assert not {"minLength", "maxLength", "minItems", "maxItems", "default", "pattern"} & node.keys()
            if node.get("type") == "object":
                assert set(node["required"]) == set(node["properties"])
                assert node["additionalProperties"] is False
            for value in node.values():
                check(value)
        elif isinstance(node, list):
            for value in node:
                check(value)

    check(schema)


async def test_provider_uses_private_bounded_responses_request_and_closes_client(monkeypatch, configured_provider):
    requests = []

    def handle(request):
        requests.append(request)
        return httpx.Response(200, json=response_json())

    clients = mock_http(monkeypatch, handle)
    result = await configured_provider.generate({"metrics": []})
    assert result.headline.text == review_json()["headline"]["text"]
    assert len(requests) == 1
    direct = isinstance(configured_provider, OpenAIResponsesProvider)
    assert requests[0].url == (
        "https://api.openai.com/v1/responses"
        if direct else "https://synthetic-resource.openai.azure.com/openai/v1/responses"
    )
    payload = json.loads(requests[0].content)
    assert payload["store"] is False
    assert payload["background"] is False
    assert payload["max_output_tokens"] == 1_500
    assert payload["model"] == (
        "synthetic-model-explicitly-configured" if direct else "synthetic-deployment"
    )
    assert payload["text"]["format"]["strict"] is True
    assert payload["text"]["format"]["schema"] == strict_review_schema()
    assert "previous_response_id" not in payload
    assert "synthetic-key" not in requests[0].content.decode()
    assert clients[0].is_closed


@pytest.mark.parametrize("status_code", [301, 307, 400, 401, 429, 500])
async def test_http_errors_are_sanitized_never_retried_or_redirected(monkeypatch, status_code, configured_provider):
    calls = []

    def handle(request):
        calls.append(request)
        return httpx.Response(
            status_code,
            headers={"Location": "https://untrusted.invalid"},
            json={"error": {"message": "private-health-data-and-provider-key"}},
        )

    clients = mock_http(monkeypatch, handle)
    with pytest.raises(ProviderUnavailableError) as error:
        await configured_provider.generate({"metrics": []})
    rendered = "".join(traceback.format_exception(error.value))
    assert "private-health-data-and-provider-key" not in rendered
    assert error.value.__cause__ is None
    assert len(calls) == 1
    assert clients[0].is_closed


@pytest.mark.parametrize("status", ["incomplete", "cancelled", "failed", "queued", "in_progress", None])
async def test_plausible_json_in_noncomplete_response_is_rejected(monkeypatch, status, configured_provider):
    payload = response_json()
    payload["status"] = status
    clients = mock_http(monkeypatch, lambda _: httpx.Response(200, json=payload))
    with pytest.raises(ProviderUnavailableError):
        await configured_provider.generate({"metrics": []})
    assert clients[0].is_closed


@pytest.mark.parametrize("kind", ["refusal", "refusal_and_text", "error", "incomplete_details", "multiple_messages", "tool_call"])
async def test_refusals_and_partial_or_unexpected_outputs_are_rejected(monkeypatch, kind, configured_provider):
    payload = response_json()
    refusal = {"type": "refusal", "refusal": "private-refusal-text"}
    if kind == "refusal":
        payload["output"][0]["content"] = [refusal]
    elif kind == "refusal_and_text":
        payload["output"][0]["content"].append(refusal)
    elif kind == "error":
        payload["error"] = {"message": "private-refusal-text"}
    elif kind == "incomplete_details":
        payload["incomplete_details"] = {"reason": "max_output_tokens"}
    elif kind == "multiple_messages":
        payload["output"].append(copy.deepcopy(payload["output"][0]))
    else:
        payload["output"].append({"type": "function_call", "name": "unexpected"})
    mock_http(monkeypatch, lambda _: httpx.Response(200, json=payload))
    with pytest.raises(ProviderUnavailableError) as error:
        await configured_provider.generate({"metrics": []})
    assert "private-refusal-text" not in str(error.value)


@pytest.mark.parametrize("kind", ["invalid_json", "missing_items", "long_text", "extra_field", "too_many_items", "oversize_text"])
async def test_model_json_is_locally_validated_after_provider_schema(monkeypatch, kind, configured_provider):
    payload = response_json()
    review = review_json()
    if kind == "missing_items":
        del review["items"]
    elif kind == "long_text":
        review["headline"]["text"] = "x" * 281
    elif kind == "extra_field":
        review["private_notes"] = "private-health-detail"
    elif kind == "too_many_items":
        review["items"] = [review["headline"]] * 4
    text = json.dumps(review)
    if kind == "invalid_json":
        text = "private-health-detail: not JSON"
    elif kind == "oversize_text":
        text = "x" * (providers.MAX_REVIEW_TEXT_CHARACTERS + 1)
    payload["output"][0]["content"][0]["text"] = text
    mock_http(monkeypatch, lambda _: httpx.Response(200, json=payload))
    with pytest.raises(ProviderUnavailableError) as error:
        await configured_provider.generate({"metrics": []})
    assert "private-health-detail" not in str(error.value)


@pytest.mark.parametrize(
    "body",
    [b"not-json", b"null", b"[]", b"{}", b"x" * 65_537, b"[" * 2_000 + b"]" * 2_000],
    ids=["non-json", "null", "array", "missing-fields", "oversize", "deep-json"],
)
async def test_malformed_or_oversized_provider_envelopes_are_rejected(monkeypatch, body, configured_provider):
    clients = mock_http(monkeypatch, lambda _: httpx.Response(200, content=body))
    with pytest.raises(ProviderUnavailableError):
        await configured_provider.generate({"metrics": []})
    assert clients[0].is_closed


async def test_oversized_stream_closes_immediately(monkeypatch, configured_provider):
    class LargeStream(httpx.AsyncByteStream):
        def __init__(self):
            self.closed = False
            self.chunks_read = 0

        async def __aiter__(self):
            for _ in range(100):
                self.chunks_read += 1
                yield b"x" * 4_096

        async def aclose(self):
            self.closed = True

    stream = LargeStream()
    clients = mock_http(monkeypatch, lambda _: httpx.Response(200, stream=stream))
    with pytest.raises(ProviderUnavailableError):
        await configured_provider.generate({"metrics": []})
    assert stream.closed
    assert stream.chunks_read == 17
    assert clients[0].is_closed


@pytest.mark.parametrize("status_code", [307, 429, 500])
async def test_error_response_bodies_are_never_read_and_streams_close(monkeypatch, status_code, configured_provider):
    class ErrorStream(httpx.AsyncByteStream):
        def __init__(self):
            self.closed = False
            self.chunks_read = 0

        async def __aiter__(self):
            self.chunks_read += 1
            yield b"private-error-body-that-must-not-be-read" * 10_000

        async def aclose(self):
            self.closed = True

    stream = ErrorStream()
    requests = []

    def handle(request):
        requests.append(request)
        return httpx.Response(status_code, stream=stream)

    clients = mock_http(monkeypatch, handle)
    with pytest.raises(ProviderUnavailableError):
        await configured_provider.generate({"metrics": []})
    assert stream.chunks_read == 0
    assert stream.closed
    assert len(requests) == 1
    assert clients[0].is_closed


async def test_provider_deadline_cancels_request_and_closes_client(monkeypatch, configured_provider):
    cancelled = asyncio.Event()

    async def handle(_):
        try:
            await asyncio.Event().wait()
        finally:
            cancelled.set()

    clients = mock_http(monkeypatch, handle)
    monkeypatch.setattr(providers, "PROVIDER_TIMEOUT_SECONDS", 0.01)
    with pytest.raises(ProviderUnavailableError):
        await configured_provider.generate({"metrics": []})
    assert cancelled.is_set()
    assert clients[0].is_closed


async def test_caller_cancellation_is_not_converted_to_provider_failure(monkeypatch, configured_provider):
    started = asyncio.Event()

    async def handle(_):
        started.set()
        await asyncio.Event().wait()

    clients = mock_http(monkeypatch, handle)
    task = asyncio.create_task(configured_provider.generate({"metrics": []}))
    await started.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert clients[0].is_closed


async def test_default_http_client_does_not_follow_redirects_or_use_environment_proxies():
    async with providers._http_client() as client:
        assert client.follow_redirects is False
        assert client.trust_env is False
        assert providers._reject_http_error in client.event_hooks["response"]


async def test_reasoning_envelope_plus_one_complete_message_is_accepted(monkeypatch, configured_provider):
    payload = response_json()
    payload["output"].insert(0, {"type": "reasoning", "summary": []})
    mock_http(monkeypatch, lambda _: httpx.Response(200, json=payload))
    result = await configured_provider.generate({"metrics": []})
    assert result.items == []


def test_provider_is_disabled_without_explicit_selection(monkeypatch):
    def forbidden():
        pytest.fail("Disabled selection must not load any provider environment")

    monkeypatch.setattr(providers, "AzureOpenAISettings", forbidden)
    monkeypatch.setattr(providers, "OpenAISettings", forbidden)
    selected = ProviderSettings(_env_file=None)
    assert selected.provider is ProviderKind.DISABLED
    assert not selected.is_configured
    assert isinstance(make_provider(selected), UnconfiguredProvider)


@pytest.mark.parametrize("selection", ["chatgpt", "pro", "auto", "", "OPENAI"])
def test_unknown_or_subscription_provider_selections_fail_closed(monkeypatch, selection):
    monkeypatch.setenv("WEEKLY_REVIEW_PROVIDER", selection)
    with pytest.raises(ValueError):
        ProviderSettings(_env_file=None)


@pytest.mark.parametrize("selection", [ProviderKind.AZURE, ProviderKind.OPENAI])
def test_explicit_selection_loads_only_its_own_settings(monkeypatch, selection):
    monkeypatch.setenv("WEEKLY_REVIEW_PROVIDER", selection.value)

    def forbidden():
        pytest.fail("Inactive provider settings must never be parsed")

    if selection is ProviderKind.AZURE:
        monkeypatch.setattr(providers, "AzureOpenAISettings", settings)
        monkeypatch.setattr(providers, "OpenAISettings", forbidden)
        expected = AzureOpenAIResponsesProvider
    else:
        monkeypatch.setattr(providers, "OpenAISettings", direct_openai_settings)
        monkeypatch.setattr(providers, "AzureOpenAISettings", forbidden)
        expected = OpenAIResponsesProvider
    selected = ProviderSettings(_env_file=None)
    assert selected.is_configured
    assert isinstance(make_provider(selected), expected)


@pytest.mark.parametrize("selection", [ProviderKind.AZURE, ProviderKind.OPENAI])
async def test_missing_selected_credentials_never_fall_back(monkeypatch, selection):
    # The other adapter has valid synthetic settings but must remain untouched.
    if selection is ProviderKind.OPENAI:
        monkeypatch.setattr(providers, "AzureOpenAISettings", settings)
    else:
        monkeypatch.setattr(providers, "OpenAISettings", direct_openai_settings)
    selected = ProviderSettings(_env_file=None, provider=selection)
    assert not selected.is_configured
    provider = make_provider(selected)
    assert isinstance(provider, UnconfiguredProvider)
    with pytest.raises(ProviderUnavailableError):
        await provider.generate({"metrics": []})


def test_invalid_azure_configuration_reports_false_without_secret_error(monkeypatch):
    monkeypatch.setattr(
        providers, "AzureOpenAISettings",
        lambda: settings("https://sensitive-user:private-secret@untrusted.invalid"),
    )
    selected = ProviderSettings(_env_file=None, provider=ProviderKind.AZURE)
    assert not selected.is_configured
    with pytest.raises(ProviderUnavailableError) as error:
        make_provider(selected)
    assert "private-secret" not in str(error.value)
    assert "sensitive-user" not in str(error.value)


def test_invalid_openai_configuration_reports_false_without_echoing_input(monkeypatch):
    monkeypatch.setenv("OPENAI_MODEL", "private-invalid-model" * 20)
    monkeypatch.setenv("OPENAI_API_KEY", "synthetic-key-not-a-credential")
    selected = ProviderSettings(_env_file=None, provider=ProviderKind.OPENAI)
    assert not selected.is_configured
    with pytest.raises(ProviderUnavailableError) as error:
        make_provider(selected)
    assert "private-invalid-model" not in str(error.value)
    assert "synthetic-key" not in str(error.value)


@pytest.mark.parametrize("model", [None, " "])
def test_openai_requires_an_explicit_nonempty_model(model):
    config = OpenAISettings(
        _env_file=None, model=model, api_key="synthetic-key-not-a-credential"
    )
    assert not config.is_configured
    with pytest.raises(ProviderUnavailableError):
        OpenAIResponsesProvider(config)


@pytest.mark.parametrize("api_key", [None, "", " "])
def test_openai_requires_nonempty_api_key(api_key):
    config = OpenAISettings(_env_file=None, model="synthetic-model", api_key=api_key)
    assert not config.is_configured
    with pytest.raises(ProviderUnavailableError):
        OpenAIResponsesProvider(config)


async def test_openai_ignores_base_url_override_and_proxy_environment(monkeypatch):
    monkeypatch.setenv("OPENAI_BASE_URL", "http://untrusted.invalid/capture")
    monkeypatch.setenv("HTTPS_PROXY", "http://untrusted.invalid:8080")
    monkeypatch.setenv("HTTP_PROXY", "http://untrusted.invalid:8080")
    requests = []

    def handle(request):
        requests.append(request)
        return httpx.Response(200, json=response_json())

    mock_http(monkeypatch, handle)
    await OpenAIResponsesProvider(direct_openai_settings()).generate({"metrics": []})
    assert len(requests) == 1
    assert requests[0].url == "https://api.openai.com/v1/responses"


async def test_selected_provider_failure_never_attempts_other_destination(monkeypatch):
    requests = []

    def handle(request):
        requests.append(request)
        return httpx.Response(503)

    monkeypatch.setattr(providers, "OpenAISettings", direct_openai_settings)
    monkeypatch.setattr(providers, "AzureOpenAISettings", settings)
    mock_http(monkeypatch, handle)
    chosen = make_provider(ProviderSettings(_env_file=None, provider=ProviderKind.OPENAI))
    with pytest.raises(ProviderUnavailableError):
        await chosen.generate({"metrics": []})
    assert len(requests) == 1
    assert requests[0].url.host == "api.openai.com"
