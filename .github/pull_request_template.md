## Summary

<!-- What changed, and why? -->

## Privacy and data boundary

- [ ] This change does not add identifiers, routes, notes, raw health samples,
      credentials, or account-specific data to a public payload, test fixture,
      log, screenshot, or documentation.
- [ ] I updated consent, schema, migration, or privacy documentation if this
      changes what is collected, stored, shared, or retained.
- [ ] I did not enable CloudKit V2 or a live Azure flow without the required
      Dashboard, authentication, and device validation.

## Verification

- [ ] `xcodebuild build-for-testing …` (or explain why it was not applicable)
- [ ] `pytest -q -p no:cacheprovider` for weekly-review changes
- [ ] Physical-device checks documented, when HealthKit/iCloud/auth/push or
      consent behavior changed

## Notes for reviewers

<!-- Call out migrations, configuration steps, or known follow-up work. -->
