# Clerestory 1.0.5 (60) validation

Released November 18, 2026. The DMG was built from `e805cee` with bundle ID `com.nininunz.Clerestory`. [GitHub release](https://github.com/Nininunz/Clerestory/releases/tag/v1.0.5)

- **Build and signing passed.** Xcode 27 CI passed. Gatekeeper accepted the notarized DMG and app. The executable contains arm64 and x86_64 slices. [CI run](https://github.com/Nininunz/Clerestory/actions/runs/44300431108)
- **Launch smoke test passed on the development Mac.** Quick Start appeared, Skip persisted after relaunch, and About showed `1.0.5 (60)`.
- **Sparkle feed verification passed.** Downloaded build 60 through the live appcast and verified the Sparkle signature, Developer ID signature, and bundled version. [Live appcast](https://nininunz.github.io/Clerestory/appcast.xml)
- **Clean-account check pending.** The disposable macOS VM stalled at startup. First-launch and permission behavior in a clean macOS account still need verification. [Issue #13](https://github.com/Nininunz/Clerestory/issues/13)
