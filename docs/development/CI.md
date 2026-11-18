# macOS build and unit-test checks

The `macOS CI` workflow runs on pull requests targeting `main`, pushes to `main`, and manual dispatch. It runs the required **Build and unit tests (Xcode 27)** check on the `xcode-27` runner with Xcode 27.2.

GitHub currently labels the `xcode-27` runner image as a public preview; see its [installed software](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

`Scripts/test-ci.sh` runs the module-core Swift package tests, builds the Release app, then runs the Debug app-hosted `ClerestoryTests` suite serially. Local ad-hoc signing needs no Apple account or signing secrets. Shell pipeline failures propagate, individual tests have time limits, and the job has a 30-minute timeout. A newer revision cancels an older run for the same PR or branch.

The native `ClerestoryUITests` target is not executed in CI. Run it on a logged-in Mac using the [native UI-test guide](UI_TESTS.md). The `IslandModulePreviewTests` catalog exporter is also excluded: use `Scripts/render-module-previews.sh` to regenerate previews. Rendering/layout assertions and fixture tests elsewhere in the unit-test target still run in CI.

Reproduce the CI check locally with Xcode 27.2 installed:

```sh
Scripts/test-ci.sh
```

The script prints a fresh temporary results directory. Set `OPENYOINK_CI_OUTPUT` to an empty directory to choose its location. An existing `unit-tests.xcresult` makes Xcode refuse the run, so use a fresh output directory for each run. `DEVELOPER_DIR` can select the installed Xcode version locally; CI pins it in the workflow.

Every completed job attempts to upload `macos-ci-results-xcode-<version>`, containing toolchain/build/test logs and the unit-test `.xcresult` bundle, retained for 14 days. No app binary or full DerivedData directory is uploaded. The workflow has read-only repository access and does not deploy or publish releases. Pages deployment remains a separate workflow.
