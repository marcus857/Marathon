# Weekly review service

This is the Python API for the app's explicit, selected-week training review. Azure OpenAI and the direct OpenAI API are selectable behind one `ReviewProvider` interface. Provider keys, generation, and validation stay off the device and out of CloudKit's public database. Selection defaults to `disabled`; no credentials or live deployment have been configured for this work. Local synthetic tests, including the SDK over mocked HTTP, are not live provider evaluations. ChatGPT plan/Pro access is not implemented.

## Reviewer quickstart: no credentials

With Python 3.12+ in an activated virtual environment, run these two commands from the repository root:

```bash
python -m pip install -e './services/weekly_review[dev]'
python -m app.demo
```

Installation downloads the package dependencies; **the demo itself is fully offline**. It uses two built-in synthetic manual workouts: 7 miles in 70 minutes against a 10-mile, 3-run plan. It prints structured JSON with `demo.synthetic_data=true`, `demo.ai_generated=false`, and an unchanged API response under `response`.

The sample deliberately leaves workout completeness unknown, so `response.status` is `insufficient_data` and `response.fallback_used` is `true`. Numeric metrics include stable IDs and synthetic workout evidence IDs; the fallback text cites its data-quality metric. This demonstrates calculation, traceability, and incomplete-data handling—not live AI generation, HealthKit ingestion, authentication, or deployed API access. It does not read service configuration, load keys, call a provider, or change your environment. The runnable module is [app/demo.py](app/demo.py).

## What it accepts

`POST /v1/weekly-reviews` accepts the versioned `weekly-review-input/v1` contract. The intended client sends only one selected, minimized review week:

- opaque per-request workout evidence IDs;
- dates, run types, distance, duration, optional aggregate HR/zones, and plan data;
- optional latest VO₂ max and a categorical break reason.

It must not include profile IDs, names, HealthKit UUIDs, CloudKit record IDs, route points, raw heart-rate samples, workout notes, or free-text break notes.

## Safety model

1. The service derives all numeric metrics itself.
2. If workout completeness is unconfirmed, import freshness is unknown/failed/not authorized, the import timestamp is missing, or the import does not cover the selected week, it returns a deterministic insufficient-data response without calling a model. Break context or note presence also produces a limited-data fallback. The contract requires exactly one matching plan.
3. Only the explicitly selected provider receives derived metrics and permitted evidence IDs, never client identity or raw route data. Requests must name the same provider the app disclosed to the user; there is no automatic fallback between providers.
4. Model output is required to use a strict JSON schema, cite only supplied evidence IDs, avoid numeric literals, and use a small allowlist of claim codes.
5. Current validation rejects unsupported evidence, numeric literals, defined prohibited terms, and claim codes not justified by deterministic metrics. It is not a complete semantic detector of every possible spelling or phrasing of advice. Provider SDK/network failures, deadlines, refusals, incomplete/malformed responses, and rejected evidence produce sanitized deterministic unavailable responses. Grounding failures allow one repair attempt; the SDK does not retry requests.
6. Apple JWT verification checks the signature, issuer, exact audience, issued-at time, expiry, and subject. Tokens, identity claims, request bodies, and generated text are not logged by application code. Request-validation errors never echo the submitted data. HTTP responses use `Cache-Control: no-store`.
7. Requests are limited to 128 KiB, including chunked bodies. Compressed input is rejected. Defaults allow six requests per verified subject per minute and twenty-four per day; identity keys are hashed and retained only in bounded process memory.

This is training reflection—not medical advice, diagnosis, treatment, injury guidance, readiness assessment, or a coaching prescription.

## Local setup

```bash
cd services/weekly_review
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'
cp .env.example .env
pytest -q -W error -p no:cacheprovider
uvicorn app.main:app --reload
```

By default both `WEEKLY_REVIEW_AUTH_MODE=disabled` and `WEEKLY_REVIEW_PROVIDER=disabled`, so generation is off even if provider keys happen to exist in the environment. `development_token` is only for local synthetic-data tests. Do not deploy it as production authentication. The test suite replaces service/provider environment values, isolates its working directory from `.env`, and blocks real HTTP transports; no provider key is needed for tests.

## App authentication

For a deployed API, set these server-only values:

```dotenv
WEEKLY_REVIEW_ENVIRONMENT=production
WEEKLY_REVIEW_AUTH_MODE=apple
WEEKLY_REVIEW_APPLE_AUDIENCE=Marcus.Marathon
```

Use the actual native app bundle identifier if it differs. The iOS app sends a fresh Sign in with Apple identity token as `Authorization: Bearer <identity-token>`. The server accepts only Apple-issued RS256 tokens for that exact audience, with required `iss`, `aud`, `sub`, `iat`, and `exp` claims. The maximum accepted token age is one hour, in addition to expiry validation. This is a short-lived bearer authorization for one stateless operation, not a durable app session; no refresh tokens or accounts are stored here. A stolen bearer token is usable until expiry/max age, so TLS and credential redaction are mandatory.

Public signing keys are fetched only from Apple's fixed HTTPS key endpoint, with bounded response size, one-hour cache, and refresh throttling. The entire Apple verification has a five-second deadline. A verification failure returns 401, key-service failure returns 503, and rate limiting returns 429 with `Retry-After`. `external` is a reserved, unavailable mode—not a working authentication bypass. Production startup refuses non-Apple authentication.

The user must separately agree in the app to send the displayed selected-week payload to the configured Python service and the named provider. Authentication alone is not data-sharing consent. A server-issued one-time nonce challenge, session-token exchange, and Apple revocation webhooks are not implemented here; the current stateless bearer design needs review before production deployment. See Apple's [identity verification guidance](https://developer.apple.com/documentation/signinwithapple/verifying-a-user) and [public signing-key endpoint](https://developer.apple.com/documentation/signinwithapplerestapi/fetch-apple%27s-public-key-for-verifying-token-signature).

## Provider selection and configuration

Configure exactly one mode on the server. Keep real keys in a secret store or ignored local environment file, never source control or app build settings.

| `WEEKLY_REVIEW_PROVIDER` | Required server configuration | Destination |
|---|---|---|
| `disabled` | None; safe default | No model request |
| `azure` | `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_DEPLOYMENT`, `AZURE_OPENAI_API_KEY` | Selected Azure HTTPS resource |
| `openai` | `OPENAI_MODEL`, `OPENAI_API_KEY` | Fixed `https://api.openai.com/v1/` |

There is no inferred provider or default model. Keys for the unselected provider are not used. `OPENAI_BASE_URL` cannot redirect the direct OpenAI adapter. Azure uses API-key authentication, not managed identity; allowed endpoint hosts are `<resource>.openai.azure.com` or `<resource>.services.ai.azure.com`, with no URL credentials, query, fragment, or custom path beyond `/openai/v1`. Confirm that the explicitly chosen model/deployment supports Responses and strict structured output; see [OpenAI's structured-output guide](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses) and [Microsoft's guide](https://learn.microsoft.com/azure/ai-services/openai/how-to/structured-outputs).

### Bind app consent to the server selection

Set two non-secret values in the app's local Xcode build settings:

```text
WEEKLY_REVIEW_API_BASE_URL = your deployed HTTPS Python service root
WEEKLY_REVIEW_PROVIDER = azure OR openai (choose one, matching the server)
```

The first value must not include `/v1/weekly-reviews`, credentials, or a query string. These populate `WeeklyReviewAPIBaseURL` and `WeeklyReviewAIProvider`; Debug builds also accept the same Run-scheme environment variables. The UI discloses the selected provider. It sends exactly one `X-Weekly-Review-Provider: azure` or `X-Weekly-Review-Provider: openai` header with the Apple-authenticated POST.

For authenticated requests, a missing, duplicated, or mismatched provider header returns **409 before metric derivation or provider construction**, even when the submitted data would otherwise produce a metrics-only response. Disabled/invalid server selection returns **503**. Matching selection with missing provider credentials produces the normal deterministic unavailable fallback. Legacy clients without the header are deliberately rejected; deploy matching app/server versions together. Changing the server provider does not silently redirect previously granted consent. No error ever causes a switch to the other provider.

`GET /health` exposes only `status`, `provider_configured`, and `authentication_mode`; invalid provider configuration reports `provider_configured=false`. This is a local configuration signal, not proof that credentials, model access, or a live provider request work.

### Shared API-key adapter controls

- `store=false`, `background=false`, at most 1,500 output tokens, and zero SDK retries.
- An 18-second attempt deadline, 15-second HTTP timeout, and a 35-second overall generation/one-repair deadline. Async clients close on completion, error, deadline, or cancellation.
- Redirects and environment proxy settings are disabled. Non-success response bodies are closed without reading; successful envelopes are capped at 64 KiB and review text at 16,384 characters. Refusals, incomplete output, malformed structure, and SDK errors become sanitized fallbacks.
- A strict schema requiring every object field, including defaulted fields, and forbidding extra properties. Length/pattern keywords are removed from the provider schema for portability; local Pydantic validation still enforces those bounds. See the [required-field rules for structured output](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses).

`store=false` does not guarantee zero provider retention, abuse-monitoring, or operational logging. Review the selected provider/account's policies before live health-data use. Code implementation does not authorize live requests: obtain separate approval for a synthetic live smoke test and any subsequent health-data transmission. Hosted HTTPS deployment and device end-to-end verification remain outstanding.

Deployment must provide TLS, gateway request/time/concurrency limits, shared rate limits across replicas, cost controls, and an approved retention/data-region policy. Prohibit SDK debug logs and request/response-body or authorization-header logging on the host, including proxy/APM tooling. The bundled per-process rate limiter resets at restart and is not a distributed quota or a substitute for gateway protection. Never put provider credentials in iOS configuration.

## ChatGPT plan/Pro path: not implemented

The `openai` option is the direct API-key route, not Sign in with ChatGPT or a Pro token. Eligible participating apps can use ChatGPT plans through a separate integration, but this private app's eligibility is unverified. The current open-source/local-host documentation directs paid or remotely hosted integrations to a separate interest process. See the [Sign in with ChatGPT quickstart](https://developers.openai.com/siwc/quickstart) and [plan-usage overview](https://developers.openai.com/siwc/token-sharing-open-source).

That path still needs eligibility/registration review; OAuth consent with state, nonce, and PKCE; secure account-bound token storage, refresh/revocation; model and usage-limit handling; an SSE adapter; and security/device tests. It cannot reuse the current API-key request unchanged: preview requests require `stream=true`, `store=false`, array-shaped `input`, and omission of `background` and `max_output_tokens`. Consult the [preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations) before implementation. Do not paste a ChatGPT access token into `OPENAI_API_KEY`.

## Before live use

1. Choose one provider, a compatible model/deployment, and an approved account/region/retention policy; securely provision its server-only key when authorized.
2. Deploy HTTPS with production Apple authentication, exact native bundle audience, redacted logs, shared quotas, and cost/concurrency limits. Check health without treating it as a live model test.
3. Configure matching app URL/provider values. Verify missing/mismatched provider headers fail closed and no cross-provider fallback occurs.
4. Obtain separate authorization for a synthetic live smoke test; verify success, rejected/refused output, incomplete data, outage, and timing for that exact model.
5. Run the consent/authentication/cancellation matrix on a physical device before authorizing any real health-data use. Record results and limitations in the [testing guide](../../docs/testing.md).

## Evaluation fixtures

`tests/` includes synthetic fixtures for complete/incomplete data, contradictory week state, stale imports, malformed/private request fields, unsupported evidence, numeric prose, prohibited medical language, one-repair/fallback behavior, body/rate limits, and Apple signature/claim/key-rotation checks. Actual-SDK/mock-HTTP tests exercise both API-key destinations, selection/mismatch failures, success, outages, refusal, and incomplete output. Provider tests cover schema normalization, endpoint restrictions, size limits, and deadlines. Signing keys are ephemeral; no real Apple credentials or external model calls are involved. These test deterministic checks and transport behavior, not the accuracy or safety of a live model. CI must remain credential-free and mocked; separately authorize any synthetic live evaluation.
