# Contributing to Clerestory

## Open an issue

[Open an issue](https://github.com/Nininunz/Clerestory/issues/new/choose) using the bug report or feature request form. For a larger change, open an issue first so we can agree on the behavior. Use disposable files or synthetic data when sharing a Shelf or Clipboard example.

## Open a pull request

- Branch from `main` and keep the PR focused on one change. Use an imperative title such as “Keep Shelf search controls fixed.”
- Write new code comments and internal developer documentation in English.
- Explain the change and why it matters. Use `Closes #123` if the PR fully resolves an issue or `Refs #123` if work remains.
- List the checks you ran and their results. Add screenshots or a recording for visible changes when helpful. For display and drag-and-drop changes, record what you verified on physical hardware or in simulation.

## Run checks

See [Build from source](README.md#build-from-source) for setup. Run `Scripts/test-ci.sh` for the build and unit tests. See the [CI guide](docs/development/CI.md), [UI test guide](docs/development/UI_TESTS.md), and [manual checks](docs/MANUAL_TESTING.md) for coverage relevant to your change.
