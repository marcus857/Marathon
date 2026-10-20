"""Verify Apple-signed identity tokens without retaining or logging credentials."""

from __future__ import annotations

import asyncio
import json
import time
from collections.abc import Awaitable, Callable

import httpx
import jwt

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_JWKS_URL = f"{APPLE_ISSUER}/auth/keys"


class InvalidIdentityToken(ValueError):
    """Generic failure: do not expose tokens, claims, or JWT library errors."""


class IdentityVerificationUnavailable(RuntimeError):
    """Apple's key service could not be safely reached."""


async def fetch_apple_keys() -> dict[str, object]:
    # Fixed HTTPS origin; token-controlled jku/x5u URLs are never followed.
    try:
        async with httpx.AsyncClient(timeout=5.0, follow_redirects=False) as client:
            async with client.stream("GET", APPLE_JWKS_URL) as response:
                response.raise_for_status()
                body = bytearray()
                async for chunk in response.aiter_bytes():
                    body.extend(chunk)
                    if len(body) > 65_536:
                        raise IdentityVerificationUnavailable("Apple authentication unavailable")
        result = json.loads(body)
        if not isinstance(result, dict):
            raise ValueError
        return result
    except (httpx.HTTPError, ValueError):
        raise IdentityVerificationUnavailable("Apple authentication unavailable") from None


class AppleIdentityVerifier:
    """Bounded key cache with rotation support and unknown-key refresh throttling."""

    def __init__(
        self,
        audience: str,
        *,
        max_age_seconds: int = 3_600,
        fetch_keys: Callable[[], Awaitable[dict[str, object]]] = fetch_apple_keys,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self._audience = audience
        self._max_age_seconds = max_age_seconds
        self._fetch_keys = fetch_keys
        self._clock = monotonic
        self._keys: dict[str, jwt.PyJWK] = {}
        self._expires_at = 0.0
        self._next_refresh_at = 0.0
        self._lock = asyncio.Lock()

    async def _key(self, kid: str) -> jwt.PyJWK:
        async with self._lock:
            now = self._clock()
            if now < self._expires_at and kid in self._keys:
                return self._keys[kid]
            if now < self._next_refresh_at:
                if now >= self._expires_at:
                    raise IdentityVerificationUnavailable("Apple authentication unavailable")
                raise InvalidIdentityToken("Invalid identity token")

            # Even unsuccessful/unknown-kid refreshes are throttled. One bad
            # caller cannot create an outgoing Apple key request per token.
            self._next_refresh_at = now + 30.0
            document = await self._fetch_keys()
            try:
                entries = document["keys"]
                if not isinstance(entries, list) or not 1 <= len(entries) <= 20:
                    raise ValueError
                keys = {}
                for entry in entries:
                    if (
                        isinstance(entry, dict)
                        and entry.get("alg") == "RS256"
                        and entry.get("kty") == "RSA"
                        and entry.get("use") == "sig"
                        and isinstance(entry.get("kid"), str)
                    ):
                        keys[entry["kid"]] = jwt.PyJWK.from_dict(entry, algorithm="RS256")
                if not keys:
                    raise ValueError
            except (ValueError, KeyError, TypeError, jwt.PyJWTError):
                raise IdentityVerificationUnavailable("Apple authentication unavailable") from None
            self._keys = keys
            self._expires_at = now + 3_600.0
            if kid not in self._keys:
                raise InvalidIdentityToken("Invalid identity token")
            return self._keys[kid]

    async def verify(self, token: str) -> str:
        """Return only the verified subject; email and other claims are discarded."""

        try:
            if not self._audience or not 1 <= len(token) <= 8_192:
                raise InvalidIdentityToken("Invalid identity token")
            header = jwt.get_unverified_header(token)
            kid = header.get("kid")
            if header.get("alg") != "RS256" or not isinstance(kid, str) or not 1 <= len(kid) <= 256:
                raise InvalidIdentityToken("Invalid identity token")
            key = await self._key(kid)
            claims = jwt.decode(
                token,
                key.key,
                algorithms=["RS256"],
                audience=self._audience,
                issuer=APPLE_ISSUER,
                leeway=30,
                options={
                    "require": ["iss", "aud", "exp", "iat", "sub"],
                    "strict_aud": True,
                },
            )
            issued_at, expires_at = claims["iat"], claims["exp"]
            if (
                isinstance(issued_at, bool)
                or not isinstance(issued_at, (int, float))
                or isinstance(expires_at, bool)
                or not isinstance(expires_at, (int, float))
                or expires_at <= issued_at
                or time.time() - issued_at > self._max_age_seconds
                or not isinstance(claims["sub"], str)
                or not 1 <= len(claims["sub"]) <= 255
            ):
                raise InvalidIdentityToken("Invalid identity token")
            return claims["sub"]
        except (jwt.PyJWTError, ValueError, TypeError, KeyError, OverflowError):
            raise InvalidIdentityToken("Invalid identity token") from None
