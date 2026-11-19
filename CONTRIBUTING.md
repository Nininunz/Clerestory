# Contributing to Clerestory

## Open an issue

[Open an issue](https://github.com/Nininunz/Clerestory/issues/new/choose) using the bug report or feature request form. For a larger change, open an issue first so we can agree on the behavior. Use disposable files or synthetic data when sharing a Shelf or Clipboard example.

## Open a pull request

- Branch from `main` and keep the PR focused on one change. Use an imperative title such as “Keep Shelf search controls fixed.”
- Write commit messages the same way: a short imperative subject, then a body that explains what changed and why.
- Write new code comments and internal developer documentation in English.
- Clerestory is English-only. Add new user-facing text to `Clerestory/Resources/Localizable.xcstrings` as an English entry; don't add other languages.
- Explain the change and why it matters. Use `Closes #123` if the PR fully resolves an issue or `Refs #123` if work remains.
- List the checks you ran and their results. Add screenshots or a recording for visible changes when helpful. For display and drag-and-drop changes, record what you verified on physical hardware or in simulation.
- Pull requests are merged with a merge commit.
- If you adapt code from [OpenYoink](https://github.com/MuQY1818/OpenYoink), credit it in the commit message with the upstream commit, for example “Adapted from MuQY1818/OpenYoink@7bb6c34 (weijue, MIT).”

[AGENTS.md](AGENTS.md) collects the full conventions in one place, including terms, privacy rules, and settings that must not change.

## Run checks

See [Build from source](README.md#build-from-source) for setup. Run `Scripts/test-ci.sh` for the build and unit tests. See the [CI guide](docs/development/CI.md), [UI test guide](docs/development/UI_TESTS.md), and [manual checks](docs/MANUAL_TESTING.md) for coverage relevant to your change.
