# Release preparation validation: November 17, 2026

Scope: `release-prep`, macOS 27.2.1 on Apple silicon, Xcode 27.2.0.
Signed candidate: 1.8.12 (53). No release has been published.

## Signed candidate

- Developer ID signature and Gatekeeper assessment passed after Sparkle updated
  1.8.11 (52) to 1.8.12 (53). Both candidates were notarized.
- Automatic local-feed discovery, user-approved install, replacement at the
  original path, and relaunch passed. File/snippet contents and a preference
  persisted. See `docs/FORK_RELEASE.md`.
- Launch with the fork's shelf test data removed succeeded; Settings opened.
  Automatic checking is enabled and currently reports a retrieval error because
  the public feed is not deployed.
- This is an existing macOS account, not a pristine user or VM. Removing the test
  preferences does not reset OS permission history or guarantee an uncached
  preferences domain. Do not treat this as a clean-account permission test.

## Outstanding release checks

- First-run onboarding was not observed in the signed candidate check. Investigate
  with a pristine account: `SettingsStore` writes migration keys before
  `AppDelegate.legacyInstallEvidence()` samples persistent preferences, which
  may classify a fresh installation as an upgrade. The existing policy unit
  tests alone do not cover that startup ordering.
- Physical external-display and hot-plug checks: not run; no external display
  available. Simulated notchless tests are not equivalent.
- Public HTTPS feed/download verification: pending publication and deployment.
- Existing upstream/development data migration: not implemented or tested.
- Intel hardware execution: not tested; the signed candidate is universal.

## Automated checks

- Release configuration build: passed.
- Module-core tests: 11 passed.
- Native UI suite: 17 executed, 16 passed, one failed; no skipped tests.
- `testFileDragApproachImportsAndDuplicateShowsNotice` failed at the
  `Already on Shelf` notice assertion (line 340), and failed again in isolation.
  The initial file import passed. Pinned duplicate feedback passed separately.
  Treat unpinned duplicate feedback as unresolved, not a green release check.
- Passed native checks include text drag-in, both Quick Look cases, hover/reentry,
  pinning, settings navigation/accessibility, and simulated notchless layout.
- Fork identity, shell syntax, whitespace, and credential-pattern checks passed.
- App-hosted unit tests: 858 passed; preview-export tests excluded as in CI.

The initial native UI attempt was interrupted because an older upstream-ID
copy intercepted input. The UI preflight now checks both bundle IDs; the old
copy was quit before rerunning. UI fixtures use isolated data and settings.
