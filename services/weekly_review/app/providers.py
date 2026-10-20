"""Explicit, disabled-by-default providers; credentials never reach the iOS app."""

from __future__ import annotations

import asyncio
import json
import re
from contextlib import aclosing
from enum import Enum
from typing import Protocol
from urllib.parse import urlsplit

import httpx
from openai import AsyncOpenAI, OpenAIError
from pydantic import Field, SecretStr, ValidationError
from pydantic_settings import BaseSettings, SettingsConfigDict

from .contracts import GeneratedReview


class ProviderUnavailableError(RuntimeError):
    """Sanitized configuration, transport, or output failure without provider data."""


PROVIDER_TIMEOUT_SECONDS = 18.0
MAX_PROVIDER_RESPONSE_BYTES = 65_536
MAX_REVIEW_TEXT_CHARACTERS = 16_384
OPENAI_API_BASE_URL = "https://api.openai.com/v1/"
_AZURE_HOST = re.compile(
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.(?:openai\.azure\.com|services\.ai\.azure\.com)"
)


class ReviewProvider(Protocol):
    async def generate(
        self, payload: dict[str, object], *, repair_reason: str | None = None
    ) -> GeneratedReview: ...


class ProviderKind(str, Enum):
    DISABLED = "disabled"
    AZURE = "azure"
    OPENAI = "openai"


class ProviderSettings(BaseSettings):
    """Selecting a provider never activates or reads another provider's settings."""

    model_config = SettingsConfigDict(
        env_file=".env", extra="ignore", populate_by_name=True, hide_input_in_errors=True
    )

    provider: ProviderKind = Field(
        default=ProviderKind.DISABLED, validation_alias="WEEKLY_REVIEW_PROVIDER"
    )

    def selected_settings(self) -> AzureOpenAISettings | OpenAISettings | None:
        if self.provider is ProviderKind.AZURE:
            return AzureOpenAISettings()
        if self.provider is ProviderKind.OPENAI:
            return OpenAISettings()
        if self.provider is ProviderKind.DISABLED:
            return None
        # Also fail closed for objects produced with unchecked model_copy/construct.
        raise ProviderUnavailableError("Weekly review provider selection is invalid")

    @property
    def is_configured(self) -> bool:
        try:
            selected = self.selected_settings()
            if selected is None or not selected.is_configured:
                return False
            if self.provider is ProviderKind.AZURE:
                _ = selected.base_url
            return True
        except (ValueError, TypeError, ProviderUnavailableError):
            return False


class AzureOpenAISettings(BaseSettings):
    """Azure-specific settings loaded only from server environment/secrets."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore", hide_input_in_errors=True)

    endpoint: str | None = Field(default=None, validation_alias="AZURE_OPENAI_ENDPOINT")
    deployment: str | None = Field(default=None, validation_alias="AZURE_OPENAI_DEPLOYMENT")
    api_key: SecretStr | None = Field(default=None, validation_alias="AZURE_OPENAI_API_KEY")

    @property
    def is_configured(self) -> bool:
        return bool(
            self.endpoint
            and self.deployment
            and self.deployment.strip()
            and self.api_key
            and self.api_key.get_secret_value().strip()
        )

    @property
    def base_url(self) -> str:
        # Credentials must only reach a deliberately configured Azure HTTPS
        # resource, never an arbitrary URL, embedded userinfo, or redirect.
        try:
            endpoint = self.endpoint or ""
            parsed = urlsplit(endpoint)
            if (
                not endpoint
                or any(character.isspace() for character in endpoint)
                or any(character in endpoint for character in ("\\", "?", "#"))
                or parsed.scheme != "https"
                or parsed.username is not None
                or parsed.password is not None
                or parsed.port not in (None, 443)
                or not _AZURE_HOST.fullmatch(parsed.hostname or "")
                or parsed.path not in ("", "/", "/openai/v1", "/openai/v1/")
            ):
                raise ValueError
            return f"https://{parsed.hostname}/openai/v1/"
        except ValueError:
            raise ProviderUnavailableError("Azure endpoint configuration is invalid") from None


class OpenAISettings(BaseSettings):
    """Direct API-key route only; no ChatGPT subscription/OAuth adapter."""

    model_config = SettingsConfigDict(
        env_file=".env", extra="ignore", populate_by_name=True, hide_input_in_errors=True
    )

    # There is no guessed/default model and no configurable credential destination.
    model: str | None = Field(default=None, min_length=1, max_length=128, validation_alias="OPENAI_MODEL")
    api_key: SecretStr | None = Field(default=None, validation_alias="OPENAI_API_KEY")

    @property
    def is_configured(self) -> bool:
        return bool(
            self.model
            and self.model.strip()
            and self.api_key
            and self.api_key.get_secret_value().strip()
        )


class UnconfiguredProvider:
    async def generate(
        self, payload: dict[str, object], *, repair_reason: str | None = None
    ) -> GeneratedReview:
        raise ProviderUnavailableError("Weekly review provider is disabled or not configured")


class _HardenedResponsesProvider:
    """Shared Responses transport, privacy controls, validation, and cancellation."""

    def __init__(self, *, base_url: str, model: str, api_key: SecretStr) -> None:
        self._base_url = base_url
        self._model = model
        self._api_key = api_key

    async def generate(
        self, payload: dict[str, object], *, repair_reason: str | None = None
    ) -> GeneratedReview:
        instructions = (
            "You write concise training reflections from supplied deterministic metrics. "
            "Return only the requested JSON schema. Use only allowed claim codes and evidence IDs. "
            "Do not include digits or numerical values in prose. Do not make medical, injury, illness, "
            "readiness, fatigue, diagnosis, treatment, or workout-prescription claims."
        )
        if repair_reason:
            instructions += f" Your previous response was rejected because: {repair_reason}. Repair it."

        # A client exists only for this attempt and closes on success, failure,
        # deadline, or cancellation. A rejected grounded claim may be repaired by
        # the caller once; the SDK never silently retries a paid model request.
        try:
            async with asyncio.timeout(PROVIDER_TIMEOUT_SECONDS):
                async with _http_client() as transport:
                    async with AsyncOpenAI(
                        base_url=self._base_url,
                        api_key=self._api_key.get_secret_value(),
                        http_client=transport,
                        timeout=15.0,
                        max_retries=0,
                    ) as client:
                        async with client.responses.with_streaming_response.create(
                            model=self._model,
                            instructions=instructions,
                            input=json.dumps(payload, separators=(",", ":"), sort_keys=True),
                            store=False,
                            background=False,
                            max_output_tokens=1_500,
                            text={
                                "format": {
                                    "type": "json_schema",
                                    "name": "weekly_review",
                                    "strict": True,
                                    "schema": strict_review_schema(),
                                }
                            },
                        ) as response:
                            body = bytearray()
                            # Close the iterator explicitly on oversize/cancel,
                            # not only the response connection. The SDK wrapper
                            # otherwise defers nested generator cleanup.
                            async with aclosing(response.http_response.aiter_bytes(chunk_size=4_096)) as chunks:
                                async for chunk in chunks:
                                    if len(body) + len(chunk) > MAX_PROVIDER_RESPONSE_BYTES:
                                        raise ProviderUnavailableError("Review provider response was rejected")
                                    body.extend(chunk)
                            return _parse_response(body)
        except (OpenAIError, httpx.HTTPError, TimeoutError, ValueError, TypeError):
            # Do not attach SDK exceptions: they can contain response content,
            # request headers, or other provider details. Cancellation is not
            # caught and still propagates to abort the request promptly.
            raise ProviderUnavailableError("Review provider generation is unavailable") from None


class AzureOpenAIResponsesProvider(_HardenedResponsesProvider):
    """Azure resource/deployment selected explicitly by server configuration."""

    def __init__(self, settings: AzureOpenAISettings) -> None:
        if not settings.is_configured or settings.deployment is None or settings.api_key is None:
            raise ProviderUnavailableError("Azure OpenAI settings are incomplete")
        super().__init__(
            base_url=settings.base_url,
            model=settings.deployment,
            api_key=settings.api_key,
        )


class OpenAIResponsesProvider(_HardenedResponsesProvider):
    """OpenAI API-key route with a fixed credential destination, not ChatGPT Pro."""

    def __init__(self, settings: OpenAISettings) -> None:
        if not settings.is_configured or settings.model is None or settings.api_key is None:
            raise ProviderUnavailableError("OpenAI API settings are incomplete")
        super().__init__(
            base_url=OPENAI_API_BASE_URL,
            model=settings.model,
            api_key=settings.api_key,
        )


def _http_client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        timeout=httpx.Timeout(15.0, connect=5.0, write=5.0, pool=5.0),
        follow_redirects=False,
        trust_env=False,
        event_hooks={"response": [_reject_http_error]},
    )


async def _reject_http_error(response: httpx.Response) -> None:
    # The SDK otherwise buffers error bodies before raising APIStatusError.
    # Their contents are neither needed nor safe to retain in an exception.
    if not response.is_success:
        await response.aclose()
        raise ProviderUnavailableError("Review provider generation is unavailable")


def _parse_response(body: bytes | bytearray) -> GeneratedReview:
    try:
        response = json.loads(body)
        if (
            not isinstance(response, dict)
            or response.get("status") != "completed"
            or response.get("error") is not None
            or response.get("incomplete_details") is not None
            or not isinstance(response.get("output"), list)
            or not 1 <= len(response["output"]) <= 20
        ):
            raise ValueError
        messages = []
        for output in response["output"]:
            if not isinstance(output, dict) or output.get("type") not in ("message", "reasoning"):
                raise ValueError
            if output["type"] == "message":
                messages.append(output)
        if len(messages) != 1:
            raise ValueError
        message = messages[0]
        content = message.get("content")
        if (
            message.get("status") != "completed"
            or message.get("role") != "assistant"
            or not isinstance(content, list)
            or len(content) != 1
            or not isinstance(content[0], dict)
            or content[0].get("type") != "output_text"
        ):
            # Refusal items and partial/multiple messages are never commentary.
            raise ValueError
        output_text = content[0].get("text")
        if not isinstance(output_text, str) or not 1 <= len(output_text) <= MAX_REVIEW_TEXT_CHARACTERS:
            raise ValueError
        review = GeneratedReview.model_validate_json(output_text)
        if review.model_fields_set != {"headline", "items", "next_focus"}:
            raise ValueError
        return review
    except (ValueError, TypeError, KeyError, ValidationError, RecursionError):
        raise ProviderUnavailableError("Review provider response was rejected") from None


def strict_review_schema() -> dict[str, object]:
    """Portable strict subset for both providers; Pydantic enforces size bounds."""

    schema = GeneratedReview.model_json_schema()

    def normalize(node: object) -> None:
        if isinstance(node, dict):
            for key in ("default", "minLength", "maxLength", "minItems", "maxItems", "pattern"):
                node.pop(key, None)
            if node.get("type") == "object":
                node["required"] = list(node.get("properties", {}))
                node["additionalProperties"] = False
            for value in node.values():
                normalize(value)
        elif isinstance(node, list):
            for value in node:
                normalize(value)

    normalize(schema)
    return schema


def make_provider(settings: ProviderSettings) -> ReviewProvider:
    """Load only the explicit selection; absence/failure never selects a fallback."""

    try:
        selected = settings.selected_settings()
        if selected is None or not selected.is_configured:
            return UnconfiguredProvider()
        if settings.provider is ProviderKind.AZURE:
            return AzureOpenAIResponsesProvider(selected)
        if settings.provider is ProviderKind.OPENAI:
            return OpenAIResponsesProvider(selected)
    except (ValueError, TypeError):
        raise ProviderUnavailableError("Selected review provider configuration is invalid") from None
    raise ProviderUnavailableError("Weekly review provider selection is invalid")
