# Weekly review service

The app has a **Weekly AI Review** screen in the weekly-training tab, an authenticated iOS network client, and a Python/FastAPI service in [`services/weekly_review`](../services/weekly_review). Azure OpenAI or the direct OpenAI API can be selected explicitly behind the same review interface. The pipeline gates commentary on deterministic metrics and data completeness, then validates the generated evidence. Selection and authentication default to disabled. Safeguards are exercised with synthetic data and mocked HTTP; provider credentials, HTTPS hosting, deployment-policy review, and live/device verification remain outstanding. No live model calls have been made for this work.

## Setup and use

The following describes the intended setup after completing the [pre-live checklist](#live-validation-checklist). Use synthetic data for development until then.

1. Configure and host the Python service over HTTPS using [the service setup guide](../services/weekly_review/README.md). Use production `apple` authentication with `WEEKLY_REVIEW_APPLE_AUDIENCE` matching the app's bundle identifier (currently `Marcus.Marathon`). Explicitly choose `WEEKLY_REVIEW_PROVIDER=azure` or `openai`. Configure that provider's key and model/deployment **only on the server**; neither Azure managed identity nor ChatGPT plan/Pro authorization is implemented.
2. In the app's local Xcode build configuration, set `WEEKLY_REVIEW_API_BASE_URL` to the HTTPS service root, without `/v1/weekly-reviews`, query parameters, or credentials. Also set `WEEKLY_REVIEW_PROVIDER` to the same `azure` or `openai` value. These populate `WeeklyReviewAPIBaseURL` and `WeeklyReviewAIProvider`; Debug builds also accept both Run-scheme environment values. Missing/invalid provider or URL configuration is rejected; no backend address or provider key is checked in.
3. Open **Weekly AI Review** for the selected week, refresh workout data, and check the displayed workout list. Confirm completeness only if the list contains the workouts you want reviewed.
4. Read the service address, named AI provider, and data disclosure, grant consent, and tap **Generate Review**. A separate Sign in with Apple prompt obtains a fresh identity token for this request without changing the app profile or requesting name/email scopes.

Opening the screen or refreshing HealthKit does not submit a review. Every transmission requires an explicit Generate/Retry action with consent enabled. Results remain in memory only; leaving the screen, changing the inputs/account, or revoking consent clears them and cancels pending work. Cancellation cannot retract data already sent. A displayed fallback is labeled **metrics only**, not AI-generated commentary.

The request includes `X-Weekly-Review-Provider`, binding the named provider to the server selection. An authenticated request with a missing, duplicated, or mismatched header returns 409 before generation, including for incomplete input. Disabled/invalid server selection returns 503. There is no automatic provider fallback. Deploy matching client/server versions together: older clients without this header are rejected. Changing providers requires updated app configuration and fresh consent, not just a silent server change.

## Data boundary

The mobile JSON payload uses one selected, schema-versioned review week and only the active user's workouts. It includes opaque request-scoped workout evidence IDs, dates, run types/sources, distance, duration, optional aggregate HR/zones, plan data, and timezone/import status. Although the contract supports dated VO₂ max and categorical break context, the current app omits them: cached VO₂ values have no actual sample timestamps, and legacy breaks are not profile-scoped. Weeks with saved break context receive metrics only until that ownership is established. The contract rejects extra plan weeks, out-of-week workouts, future weeks, and free-text plan notes.

It intentionally excludes:

- user/profile/CloudKit/HealthKit identifiers in the review JSON;
- route coordinates and raw heart-rate samples;
- workout notes and free-text break notes;
- provider credentials.

Authentication is separate: the HTTP Bearer header contains an Apple identity token, including its Apple account subject. The backend verifies Apple's signature, issuer, audience, issuance time, and expiry; the token is not passed to either AI provider. The service rejects unknown JSON fields rather than silently accepting them. Only the selected provider receives derived metrics, quality context, and allowed claims—not the original workout list or authentication token.

The iOS client uses an ephemeral session, disables caches/cookies, rejects redirects, bounds response size/time, and validates schema, request ID, and evidence references before display. It does not persist tokens or responses. Both API-key adapters set `store=false` and `background=false`; these settings do **not** guarantee that the provider has no retention, abuse-monitoring, or operational logs. Review the chosen account/deployment's retention/region policies, and prohibit SDK, request-body, response-body, and authorization-header debug logging on the host.

## Grounding and incomplete data

Before model generation, the service computes weekly mileage, qualifying runs, duration, weighted pace, HR coverage, plan requirements, and data-quality flags. The app marks the data complete only after a successful Health import for that same user/week within the last **15 minutes**, plus the user's confirmation of the workout list. HealthKit does not disclose whether every read permission was granted, so a successful query alone is not evidence of complete access.

The existing Health importer is additive: it does not reconcile deleted or edited Health records. It filters running/walking workouts to at least eight minutes and no slower than fifteen minutes per mile. The screen discloses these limits and asks the user to verify the list and values; a fresh query is not a claim of full HealthKit synchronization.

With matching app/server provider selection, an unknown, failed, stale, or unconfirmed import produces a deterministic insufficient-data response without calling a model. Categorical break context produces a limited-data fallback. Current-week reviews are explicitly treated as in-progress rather than final adherence judgments. Provider SDK/network errors, deadlines, refusals, incomplete or malformed responses, and rejected evidence return sanitized deterministic unavailable fallbacks rather than provider content.

For a complete request, the model receives only derived metrics plus an allowlist of claim codes and evidence IDs. The strict schema requires every object field, including defaulted `items`, and forbids extra properties; provider schema normalization removes length/pattern keywords for portability while local Pydantic validation retains the bounds. Requiring every field follows the [structured-output specification](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses). Live compatibility with the explicitly selected model/deployment still needs verification.

Instructions require supplied metric citations, no numeric literals, and no medical, injury, readiness, fatigue, diagnostic, treatment, or schedule-prescribing language. Current validation rejects unsupported evidence, numeric literals, defined prohibited terms, and claim-to-metric mismatches; grounding failures receive at most one repair attempt. This is not a complete semantic detector of every possible spelling or phrasing of advice.

## Current implementation state

Implemented in code:

- iOS selected-week refresh, allowlisted request builder, consent UI, fresh Apple authorization, cancellable client, and evidence-linked review display;
- FastAPI endpoint, strict Pydantic contracts, and Apple-signed identity-token verification;
- deterministic metric derivation and complete/limited/insufficient/unavailable states;
- explicit `disabled`/`azure`/`openai` server selection, consent-bound provider headers, and no cross-provider fallback;
- async Azure/direct OpenAI Responses adapters with strict-schema normalization, restricted destinations, disabled response storage/background mode, bounded output/time, and sanitized failure/refusal handling;
- mocked/synthetic tests for request privacy/freshness, client errors, authentication, request limits, incomplete-data gating, citation grounding, invented numeric prose, and prohibited health language;
- credential-free mocked tests and a GitHub Actions workflow that does not use provider secrets.

The service defaults to disabled authentication and provider selection until configured; it never selects a provider just because a key exists. Built-in limits default to **6 requests/minute and 24/day per verified subject**, a **128 KiB request body**, and an Apple token age of at most **one hour**. Limits use bounded process-local memory with hashed subjects; restarts reset them and multiple workers do not share them. They do not replace gateway-level/distributed limits or deployment monitoring.

Apple verification has a five-second total deadline. Provider attempts have an 18-second deadline, 15-second HTTP timeout, no SDK retries, and a 1,500-token output limit. Generation plus its one allowed grounding repair has a 35-second deadline. Successful provider responses are capped at 64 KiB and review text at 16,384 characters; non-success bodies are closed unread. Async HTTP clients close on completion, failure, or cancellation. Azure permits only configured HTTPS resource hosts under `openai.azure.com` or `services.ai.azure.com`; direct OpenAI uses fixed `https://api.openai.com/v1/`. Redirects, environment proxy settings, and arbitrary direct-OpenAI base URLs are disabled.

## ChatGPT plan/Pro is a separate future integration

`WEEKLY_REVIEW_PROVIDER=openai` means a server-side OpenAI API key and explicit `OPENAI_MODEL`, not a ChatGPT subscription or OAuth token. ChatGPT plan access can exist for eligible participating apps, but this private, remotely hosted design has not been approved or verified. Review the [Sign in with ChatGPT quickstart](https://developers.openai.com/siwc/quickstart) and [current plan-usage scope](https://developers.openai.com/siwc/token-sharing-open-source) before choosing that path.

Remaining work is distinct: registration/eligibility, OAuth and consent, secure token renewal/revocation, account/model/usage-limit handling, SSE event parsing, and security/device tests. The preview requires `stream=true`, `store=false`, array `input`, and omitting `background` and `max_output_tokens`; current API-key requests cannot simply be reused with a different token. These are documented [preview constraints](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations), not implemented capabilities.

## Live validation checklist

1. Choose Azure or direct OpenAI explicitly, configure the compatible deployment/model and server-only key, then obtain authorization for a synthetic live smoke test. Verify that exact model's structured-output compatibility and output quality; mocked transport tests do not establish either. Code approval does not authorize live data transmission.
2. Deploy the HTTPS API with matching Apple audience, gateway/resource controls, prohibited sensitive debug logs, and reviewed retention/data-region policies.
3. Configure the app's service URL and matching provider, then run authorized device-level Apple-authentication, consent/denial, provider mismatch, incomplete-data, cancellation, outage, and successful-review cases.

The current implementation is a provider-selectable weekly-review prototype with connected and synthetically tested client/server/provider code, awaiting live deployment and end-to-end verification. Each provider must be validated separately: a direct OpenAI test would not establish a successful Azure deployment. ChatGPT plan/Pro remains unimplemented.
