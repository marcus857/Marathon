"""FastAPI entry point for the evidence-grounded weekly review service."""

from __future__ import annotations

import asyncio
import hmac
from contextlib import asynccontextmanager
from functools import lru_cache
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from .auth import AppleIdentityVerifier, IdentityVerificationUnavailable, InvalidIdentityToken
from .contracts import ReviewStatus, WeeklyReviewRequest, WeeklyReviewResponse
from .limits import PrivateRequestMiddleware, SubjectRateLimiter
from .metrics import derive_metrics, deterministic_fallback
from .providers import ProviderKind, ProviderSettings, ProviderUnavailableError, make_provider
from .settings import AuthMode, ServiceSettings
from .validation import UnsupportedReviewError, accepted_response

# Covers generation plus the single permitted grounding-repair attempt. This
# plus bounded Apple authorization fits the app's 45-second HTTP request timeout.
# The deadline cancels the underlying async provider operation rather than
# abandoning a worker thread.
MAX_REVIEW_SECONDS = 35.0
MAX_APPLE_AUTH_SECONDS = 5.0


@lru_cache
def service_settings() -> ServiceSettings:
    return ServiceSettings()


@lru_cache
def provider_settings() -> ProviderSettings:
    try:
        return ProviderSettings()
    except ValidationError:
        # Configuration errors can contain the original environment value.
        raise ProviderUnavailableError("Weekly review provider configuration is invalid") from None


@lru_cache
def apple_identity_verifier() -> AppleIdentityVerifier:
    settings = service_settings()
    return AppleIdentityVerifier(
        settings.apple_audience or "",
        max_age_seconds=settings.apple_token_max_age_seconds,
    )


@lru_cache
def request_limiter() -> SubjectRateLimiter:
    settings = service_settings()
    return SubjectRateLimiter(settings.requests_per_minute, settings.requests_per_day)


@asynccontextmanager
async def lifespan(_: FastAPI):
    service_settings().validate_for_startup()
    provider_settings()  # Unknown provider names fail closed, without echoing config.
    yield


app = FastAPI(
    title="Marathon weekly review",
    version="0.1.0",
    description="Evidence-grounded training reflection API; not medical advice.",
    lifespan=lifespan,
)
app.add_middleware(PrivateRequestMiddleware, max_bytes=lambda: service_settings().max_request_bytes)


@app.exception_handler(RequestValidationError)
async def private_validation_error(_: Request, __: RequestValidationError) -> JSONResponse:
    # FastAPI's default 422 includes offending input values. Do not reflect
    # submitted health data (or unexpected private fields) in an HTTP error.
    return JSONResponse(
        status_code=422,
        content={"detail": "The weekly review request is invalid. Refresh your data and try again."},
    )


async def require_authorization(
    authorization: Annotated[str | None, Header()] = None,
    settings: ServiceSettings = Depends(service_settings),
) -> str:
    """Accept verified Apple identity tokens; never forward identity to a model provider."""

    try:
        settings.validate_for_startup()
    except RuntimeError:
        raise HTTPException(status_code=503, detail="Weekly review authentication is unavailable.") from None

    if settings.auth_mode is AuthMode.DISABLED:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Weekly review API authentication is not configured.",
        )
    if settings.auth_mode is AuthMode.EXTERNAL:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="An external authentication verifier must be configured before use.",
        )

    scheme, _, supplied = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not 1 <= len(supplied) <= 8_192:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Sign in with Apple again to request a weekly review.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    if settings.auth_mode is AuthMode.APPLE:
        try:
            async with asyncio.timeout(MAX_APPLE_AUTH_SECONDS):
                subject = await apple_identity_verifier().verify(supplied)
        except InvalidIdentityToken:
            raise HTTPException(
                status_code=401,
                detail="Sign in with Apple again to request a weekly review.",
                headers={"WWW-Authenticate": "Bearer"},
            ) from None
        except (IdentityVerificationUnavailable, TimeoutError):
            raise HTTPException(status_code=503, detail="Apple authentication is unavailable.") from None
    else:
        expected = settings.development_token.get_secret_value() if settings.development_token else ""
        if not expected or not hmac.compare_digest(supplied.encode(), expected.encode()):
            raise HTTPException(
                status_code=401,
                detail="Invalid weekly-review development token.",
                headers={"WWW-Authenticate": "Bearer"},
            )
        subject = "local-synthetic-development"

    retry_after = request_limiter().retry_after(subject)
    if retry_after is not None:
        raise HTTPException(
            status_code=429,
            detail="Weekly review request limit reached. Please try again later.",
            headers={"Retry-After": str(retry_after)},
        )
    return subject


@app.get("/health")
async def health() -> dict[str, object]:
    """No credentials, request data, or provider details are returned here."""

    try:
        configured = provider_settings().is_configured
    except ProviderUnavailableError:
        configured = False
    return {
        "status": "ok",
        "provider_configured": configured,
        "authentication_mode": service_settings().auth_mode.value,
    }


@app.post("/v1/weekly-reviews", response_model=WeeklyReviewResponse)
async def create_weekly_review(
    request: WeeklyReviewRequest,
    _: str = Depends(require_authorization),
    consented_providers: Annotated[
        list[str] | None, Header(alias="X-Weekly-Review-Provider")
    ] = None,
) -> WeeklyReviewResponse:
    try:
        selected = provider_settings()
    except ProviderUnavailableError:
        raise HTTPException(status_code=503, detail="Weekly review provider is unavailable.") from None
    if selected.provider is ProviderKind.DISABLED:
        raise HTTPException(status_code=503, detail="Weekly review AI provider is not enabled.")
    # The installed app names the recipient in its consent screen. A deployment
    # change must never silently route that consent to a different provider.
    # Reject missing, duplicate, unknown, or mismatched values before generating
    # metrics or constructing any adapter, even for a limited-data request.
    if consented_providers != [selected.provider.value]:
        raise HTTPException(
            status_code=409,
            detail="The configured review provider changed. Update the app configuration and consent again.",
        )

    context = derive_metrics(request)
    if not context.can_call_model:
        return deterministic_fallback(context)

    try:
        async with asyncio.timeout(MAX_REVIEW_SECONDS):
            provider = make_provider(selected)
            try:
                candidate = await provider.generate(context.provider_payload())
                return accepted_response(context, candidate)
            except UnsupportedReviewError:
                # One repair only. Never echo generated prose or health data
                # into logs or into an error prompt.
                try:
                    repaired = await provider.generate(
                        context.provider_payload(),
                        repair_reason="The response failed evidence grounding or safety validation.",
                    )
                    return accepted_response(context, repaired)
                except (ProviderUnavailableError, UnsupportedReviewError):
                    return deterministic_fallback(
                        context,
                        status=ReviewStatus.UNAVAILABLE,
                        additional_code="provider_response_rejected",
                    )
    except (ProviderUnavailableError, TimeoutError):
        return deterministic_fallback(
            context,
            status=ReviewStatus.UNAVAILABLE,
            additional_code="provider_unavailable",
        )
