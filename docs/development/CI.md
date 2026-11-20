# macOS build and unit-test checks

The `macOS CI` workflow runs on pull requests targeting `main`, pushes to `main`, and manual dispatch. The `main` ruleset requires one check, **Build and unit tests (Xcode 27)**. It does not require branches to be up to date before merging.

## Jobs

| Job | Runner | What it does |
| --- | --- | --- |
| Detect code changes | `ubuntu-latest` | Classifies the PR's changed files. |
| Package tests and identity check | `ubuntu-latest` | Runs `Scripts/check-identity.py` and the `ClerestoryModuleCore` package tests with the image's Swift toolchain. The package imports only Foundation. |
| Release build (Xcode 27) | `xcode-27` | Builds the app in the Release configuration, then builds the [Low Power Mode helper](../LOW_POWER_MODE_HELPER.md) and its package with an ad-hoc signature and checks the package contents. |
| Unit tests (Xcode 27) | `xcode-27` | Builds Debug and runs the app-hosted `ClerestoryTests` suite in parallel across three workers. |
| Build and unit tests (Xcode 27) | `ubuntu-latest` | The required gate. It passes only if the three check jobs passed, or if they were skipped for a documentation-only PR. It fails if any of them failed, was cancelled, or did not run on a code change. If change detection itself fails, every check runs and their results decide. |

The three check jobs run at the same time, so a PR waits for the slowest one rather than for all of them in sequence.

**Documentation-only PRs.** If every changed file is root-level Markdown, under `docs/`, or a GitHub issue or pull request template, the build and test jobs are skipped and the gate passes. `docs/appcast.xml`, `LICENSE`, `TestFixtures/`, workflow files, and everything else still build. Pushes to `main` and manual runs always build. If change detection fails, everything runs.

**Release builds.** The Release build is the only check that compiles the app without `DEBUG`, so it catches code that uses debug-only helpers outside `#if DEBUG`. Pull requests get a fast, unoptimized Release compile for the runner's architecture. Pushes to `main`, manual runs, and PRs that change the Xcode project, `.xcconfig` files, `Package.swift`, workflow files, or `Scripts/test-ci.sh` get the full optimized Release build for Apple silicon and Intel, like a shipped build. Each run on `main` has its own concurrency group, so newer merges never cancel or replace it and every merge gets the full build. Newer commits on a PR cancel that PR's older run.

GitHub currently labels the `xcode-27` runner image as a public preview; see its [installed software](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md). Each run uses two macOS runners at once.

The native `ClerestoryUITests` target is not executed in CI. Run it on a logged-in Mac using the [native UI-test guide](UI_TESTS.md). The `IslandModulePreviewTests` catalog exporter is also excluded: use `Scripts/render-module-previews.sh` to regenerate previews. Rendering/layout assertions and fixture tests elsewhere in the unit-test target still run in CI.

## Run the checks locally

With Xcode 27.2 installed, run every phase in order:

```sh
Scripts/test-ci.sh
```

Pass `identity`, `module-core`, `release`, `helper`, or `unit-tests` to run a single phase, as CI does. Set `CLERESTORY_RELEASE_BUILD=fast` for the quicker PR-style Release compile; the default is the full build.

The script prints a fresh temporary results directory. Set `CLERESTORY_CI_OUTPUT` to an empty directory to choose its location. An existing `unit-tests.xcresult` makes Xcode refuse the run, so use a fresh output directory for each run. `DEVELOPER_DIR` can select the installed Xcode version locally; CI pins it in the workflow. Package versions come only from the committed `Package.resolved`.

Local ad-hoc signing needs no Apple account or signing secrets. Shell pipeline failures propagate, individual tests have time limits, and each job has a timeout.

## Logs and results

The Release job uploads `ci-release-build-xcode-<version>` with its logs. The unit-test job uploads `ci-unit-tests-xcode-<version>` with its logs and the `.xcresult` bundle. Both are kept for 14 days. No app binary or full DerivedData directory is uploaded. The workflow has read-only repository access and does not deploy or publish releases.
