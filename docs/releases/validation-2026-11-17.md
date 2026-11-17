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

## Issues found and fixed in follow-up

- Duplicate drop feedback now closes a transient drag-opened panel before
  presenting its notice. Previously, accepting the drop kept the panel expanded
  while the notice waited indefinitely for it to close. Pinned panels remain open.
- Onboarding now captures existing-install evidence before settings migrations
  or services write startup data. Added migration-order unit coverage and a
  native first-launch/Skip test.

## Outstanding release checks

- Rebuild the signed release candidate with the follow-up fixes and repeat the
  first-run smoke check. The earlier signed 1.8.12 (53) artifact predates them.
  A pristine-account OS-permission check remains separate from the isolated UI test.
- Physical external-display and hot-plug checks: not run; no external display
  available. Simulated notchless tests are not equivalent.
- Public HTTPS feed/download verification: pending publication and deployment.
- Existing upstream/development data migration: not implemented or tested.
- Intel hardware execution: not tested; the signed candidate is universal.

## Initial automated checks (before follow-up fixes)

- Release configuration build: passed.
- Module-core tests: 11 passed.
- Native UI suite: 17 executed, 16 passed, one failed; no skipped tests.
- `testFileDragApproachImportsAndDuplicateShowsNotice` failed at the
  `Already on Shelf` notice assertion (line 340), and failed again in isolation.
  The initial file import passed. Pinned duplicate feedback passed separately.
  This failure motivated the follow-up fix above; see final rerun results below.
- Passed native checks include text drag-in, both Quick Look cases, hover/reentry,
  pinning, settings navigation/accessibility, and simulated notchless layout.
- Fork identity, shell syntax, whitespace, and credential-pattern checks passed.
- App-hosted unit tests: 858 passed; preview-export tests excluded as in CI.

The initial native UI attempt was interrupted because an older upstream-ID
copy intercepted input. The UI preflight now checks both bundle IDs; the old
copy was quit before rerunning. UI fixtures use isolated data and settings.

## Follow-up verification

The final follow-up source passed 861 app unit tests and all 18 native UI tests,
including first-launch onboarding/Skip, the formerly failing unpinned duplicate
notice, and pinned duplicate feedback. Preview-export tests were excluded as in
CI. The focused run also passed all 56 selected unit tests and three native UI
checks. No test expectations were relaxed to hide the original failure.

The signed candidate and update-test artifacts predate these source fixes; a
new signed candidate is still required before publication.
