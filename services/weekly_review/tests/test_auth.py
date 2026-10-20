from __future__ import annotations

import json
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from app.auth import (
    APPLE_ISSUER,
    AppleIdentityVerifier,
    IdentityVerificationUnavailable,
    InvalidIdentityToken,
)
from app.settings import AuthMode, ServiceSettings


@pytest.fixture(scope="module")
def signing_key():
    return rsa.generate_private_key(public_exponent=65_537, key_size=2_048)


def key_document(key, kid="test-key"):
    public = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    return {"keys": [{**public, "kid": kid, "alg": "RS256", "use": "sig"}]}


def token(key, *, overrides=None, kid="test-key"):
    now = int(time.time())
    claims = {
        "iss": APPLE_ISSUER,
        "aud": "Marcus.Marathon",
        "sub": "synthetic-private-subject",
        "iat": now,
        "exp": now + 600,
    }
    claims.update(overrides or {})
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": kid})


async def test_apple_signature_and_claims_are_verified_and_keys_are_cached(signing_key):
    fetch_count = 0

    async def fetch():
        nonlocal fetch_count
        fetch_count += 1
        return key_document(signing_key)

    verifier = AppleIdentityVerifier("Marcus.Marathon", fetch_keys=fetch)
    for _ in range(2):
        assert await verifier.verify(token(signing_key)) == "synthetic-private-subject"
    assert fetch_count == 1


@pytest.mark.parametrize(
    "overrides",
    [
        {"iss": "https://untrusted.invalid"},
        {"aud": "another.application"},
        {"aud": ["Marcus.Marathon", "another.application"]},
        {"exp": 1},
        {"iat": 1},
        {"iat": int(time.time()) + 600},
        {"sub": ""},
        {"sub": None},
        {"iat": True},
        {"exp": float("inf")},
    ],
)
async def test_invalid_apple_claims_fail_closed(signing_key, overrides):
    async def fetch():
        return key_document(signing_key)

    verifier = AppleIdentityVerifier("Marcus.Marathon", fetch_keys=fetch)
    with pytest.raises(InvalidIdentityToken, match="^Invalid identity token$"):
        await verifier.verify(token(signing_key, overrides=overrides))


async def test_wrong_signature_is_rejected(signing_key):
    wrong_key = rsa.generate_private_key(public_exponent=65_537, key_size=2_048)

    async def fetch():
        return key_document(signing_key)

    verifier = AppleIdentityVerifier("Marcus.Marathon", fetch_keys=fetch)
    with pytest.raises(InvalidIdentityToken):
        await verifier.verify(token(wrong_key))


@pytest.mark.parametrize("invalid_token", ["bad-token", "x" * 8_193, ""])
async def test_malformed_tokens_do_not_fetch_keys(invalid_token):
    async def fetch():
        pytest.fail("Malformed tokens must not trigger key fetches")

    verifier = AppleIdentityVerifier("Marcus.Marathon", fetch_keys=fetch)
    with pytest.raises(InvalidIdentityToken):
        await verifier.verify(invalid_token)


async def test_unknown_key_refresh_is_throttled_and_rotation_works(signing_key):
    clock = [100.0]
    fetch_count = 0

    async def fetch():
        nonlocal fetch_count
        fetch_count += 1
        return key_document(signing_key, "rotated" if fetch_count > 1 else "test-key")

    verifier = AppleIdentityVerifier("Marcus.Marathon", fetch_keys=fetch, monotonic=lambda: clock[0])
    await verifier.verify(token(signing_key))
    for _ in range(3):
        with pytest.raises(InvalidIdentityToken):
            await verifier.verify(token(signing_key, kid="rotated"))
    assert fetch_count == 1
    clock[0] += 31
    assert await verifier.verify(token(signing_key, kid="rotated")) == "synthetic-private-subject"
    assert fetch_count == 2


async def test_apple_outage_is_sanitized_and_failures_are_throttled(signing_key):
    count = 0

    async def fetch():
        nonlocal count
        count += 1
        raise IdentityVerificationUnavailable("Apple authentication unavailable")

    verifier = AppleIdentityVerifier("Marcus.Marathon", fetch_keys=fetch)
    for _ in range(2):
        with pytest.raises(IdentityVerificationUnavailable):
            await verifier.verify(token(signing_key))
    assert count == 1


@pytest.mark.parametrize("mode", [AuthMode.DISABLED, AuthMode.DEVELOPMENT_TOKEN, AuthMode.EXTERNAL])
def test_production_rejects_non_apple_authentication(mode):
    settings = ServiceSettings(_env_file=None, environment="production", auth_mode=mode)
    with pytest.raises(RuntimeError, match="requires Apple authentication"):
        settings.validate_for_startup()


def test_apple_authentication_requires_explicit_audience():
    settings = ServiceSettings(_env_file=None, auth_mode=AuthMode.APPLE, apple_audience=None)
    with pytest.raises(RuntimeError, match="APPLE_AUDIENCE"):
        settings.validate_for_startup()
    settings.apple_audience = "Marcus.Marathon"
    settings.validate_for_startup()
