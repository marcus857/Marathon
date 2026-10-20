"""Server-only authentication and resource-limit configuration."""

from __future__ import annotations

from enum import Enum

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class AuthMode(str, Enum):
    DISABLED = "disabled"
    DEVELOPMENT_TOKEN = "development_token"
    APPLE = "apple"
    EXTERNAL = "external"


class ServiceSettings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_prefix="WEEKLY_REVIEW_",
        extra="ignore",
    )

    environment: str = "development"
    auth_mode: AuthMode = AuthMode.DISABLED
    development_token: SecretStr | None = None
    apple_audience: str | None = Field(default=None, min_length=1, max_length=255)
    apple_token_max_age_seconds: int = Field(default=3_600, ge=60, le=3_600)
    requests_per_minute: int = Field(default=6, ge=1, le=60)
    requests_per_day: int = Field(default=24, ge=1, le=1_000)
    max_request_bytes: int = Field(default=131_072, ge=1_024, le=262_144)

    def validate_for_startup(self) -> None:
        if self.environment.lower() == "production" and self.auth_mode is not AuthMode.APPLE:
            raise RuntimeError("Production weekly-review service requires Apple authentication")
        if self.auth_mode is AuthMode.APPLE and not self.apple_audience:
            raise RuntimeError("Apple authentication requires WEEKLY_REVIEW_APPLE_AUDIENCE")
        if self.auth_mode is AuthMode.DEVELOPMENT_TOKEN and (
            self.development_token is None or not self.development_token.get_secret_value()
        ):
            raise RuntimeError("development_token auth requires WEEKLY_REVIEW_DEVELOPMENT_TOKEN")
