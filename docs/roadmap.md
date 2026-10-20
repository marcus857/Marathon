# Roadmap and release checklist

The repository is a documented, locally tested prototype. Checked items below describe implemented code, not an approved production health-data system or a live AI deployment.

## Implemented foundations

- [x] Fix fresh-install identity and onboarding behavior.
- [x] Stop creation of new route-coordinate persistence and uploads; legacy public route payloads still need owner-scoped remediation or deletion before broad testing.
- [x] Add a disabled V2 record/projection foundation that separates private personal records from public team summaries.
- [x] Keep debug bulk-post/delete tools out of release builds.
- [x] Add a unit-test target for deterministic domain logic.
- [x] Reconcile shared workouts through one snapshot across tabs, preserving pending personal edits and retaining cached data on refresh failures.
- [x] Document architecture, setup, test scope, and known privacy limitations.

## Before broader sharing or distribution

- [x] Replace undocumented image assets with newly generated project artwork and record prompts, output hashes, and intended uses; see [asset provenance](asset-attribution.md).
- [x] Verify that old raster blobs are absent from the clean publication snapshot and its text-only ancestor. Preserve the unpublished local history separately; never merge or mirror that history into the public branch.
- [ ] Make an explicit license decision before offering reuse permissions; no open-source license is currently selected, and generated provenance is not a rights guarantee.
- [ ] Replace account-specific signing, bundle, and CloudKit identifiers for builds outside the original development account.
- [ ] Replace the legacy public `WorkoutEntry` design with private personal records and separately modeled, minimized team summaries.
- [ ] Remediate or delete legacy public route payloads under their owners' authority.
- [ ] Verify CloudKit schema, server-side roles, and queries in development with test accounts.
- [ ] Validate same-account and separate-account device flows before inviting testers with real data.
- [ ] Define account deletion, data export, and retention workflows.

## Before claiming reliable cross-device synchronization

- [ ] Define a source-of-truth and conflict policy for run-type edits and other mutable workout fields.
- [ ] Add retry/recovery behavior for temporarily unavailable iCloud accounts.
- [x] Prevent fallback to an unintended CloudKit container.
- [x] Cover snapshot deletion/unsharing, failed reads, and pending-edit preservation with synthetic tests.
- [ ] Complete the documented physical-device matrix for offline recovery, deletion, and push-notification behavior.

## Weekly-review service

The iOS/Python pipeline has selectable Azure/direct OpenAI adapters, a deterministic metric engine, structured-output validation, and synthetic tests:

1. [x] A typed weekly-metrics contract assembled from deterministic calculations.
2. [x] An Apple-authenticated Python API that keeps model credentials off the device; production authentication/security review remains required.
3. [x] Structured model responses with a versioned schema.
4. [x] Evidence IDs connecting every review claim to specific metric inputs.
5. [x] A validator that rejects unsupported evidence, numeric literals, defined prohibited terms, and claim/metric mismatches.
6. [x] Explicit limited/insufficient-data responses for incomplete imports or context; missing or invalid required plans are rejected by the input contract.
7. [x] Fixture-based tests of incomplete-data handling, invented numeric prose, unknown citations, and prohibited terms. These test validators, not live-model output quality.
8. [x] Explicit, disabled-by-default Azure/direct OpenAI selection and provider-bound consent, with no automatic provider fallback.
9. [x] iOS consent, authenticated client, review UI, and connected allowlisted request builder, tested against synthetic responses.
10. [ ] Configure an approved provider/model and server-only credentials, then host the HTTPS service with matching Apple audience, gateway quotas, cost controls, and redacted logging.
11. [ ] Run authorized synthetic live tests against that exact model/deployment, recording response quality, unsupported claims, incomplete-data behavior, latency, and failure cases.
12. [ ] Complete physical-device consent, Apple sign-in, cancellation, and end-to-end review validation with matching app/server provider settings.
13. [ ] If pursuing ChatGPT plan/Pro usage: establish eligibility and implement its separate OAuth/token lifecycle and streaming adapter. The API-key adapters do not provide this integration.

Metrics-only fallbacks must remain visibly distinct from generated commentary. See the [weekly-review launch checklist](weekly-review.md#live-validation-checklist) and [testing matrix](testing.md) for acceptance criteria.
