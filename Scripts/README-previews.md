# Module previews

Run from any directory. Fixtures render the actual module views with isolated sample stores and preferences; they do not change your Shelf contents.

```sh
# Every module and scenario, with the gallery opened afterward
Scripts/render-module-previews.sh

# Discover available scenarios (no image rendering)
Scripts/render-module-previews.sh --list
Scripts/render-module-previews.sh --module shelf --list

# Capture several matching scenarios; repeated filters are combined with OR
Scripts/render-module-previews.sh --module shelf --scenario duplicate --scenario stack

# Multiple modules, offscreen capture, no browser
Scripts/render-module-previews.sh --module shelf --module battery --capture snapshot --no-open

# Pick the destination
Scripts/render-module-previews.sh --module shelf --output /tmp/my-shelf-previews
```

Module slugs: `battery`, `timer`, `now-playing`, `ai-usage`, `clipboard`, `quick-access`, `shelf`, `transfers`, `system-status`, `quick-settings`.

`--scenario` matches case-insensitive substrings of scenario IDs or labels. Shelf IDs are stable even when their display labels change. A filter with no matches fails rather than silently producing an empty gallery. `--list` still builds and runs the fixture catalog so its labels stay in sync with the code.

The default `window` capture briefly displays each preview window and captures it with macOS's compositor, preserving blur and material backgrounds. Screen Recording permission may be required for the invoking terminal/app. `snapshot` captures offscreen without that permission, but blur and translucent materials may be missing. Captures reserve the navigation band; they don't reproduce live shortcut controls or the controller-owned drag outline. Static images do not demonstrate animation or scrolling.

Each run defaults to a new `/tmp/openyoink-previews-*` directory with `index.html`, per-module contact sheets, named scenario PNGs, `manifest.json`, and `build.log`. Explicit output directories can retain older files; the manifest/gallery identify this run's results. One runner may execute at a time. The runner removes its temporary request configuration on exit.

Add Shelf cases to `OpenYoinkTests/TestKit/Shelf/ShelfScenario.swift` using real state/store inputs. Other modules still use the compatibility adapter in `IslandModulePreviewTests.swift`. All added cases automatically appear in listing, filtering, the manifest, and the gallery. Shelf includes empty, populated, selected, search-empty, importing, duplicate-drop, expanded-stack, stack-selection, long-name, large-grid, and keyboard-focus samples.

## Test kit structure

- `OpenYoinkTests/TestKit/ModuleScenario.swift`: lazy view factories, stable scenario IDs, and isolated preference lifetime.
- `OpenYoinkTests/TestKit/ModulePreviewRenderer.swift`: shared Island outer layout, captures, contact sheets, filtering, and manifest generation.
- `OpenYoinkTests/TestKit/Shelf/ShelfSampleFiles.swift`: reproducible synthetic document/artwork generator.
- `OpenYoinkTests/TestKit/Shelf/ShelfFixtures.swift`: fresh reusable sample data with no dependency on user files.
- `OpenYoinkTests/TestKit/Shelf/ShelfScenario.swift`: typed scenario catalog and inspectable store/interaction state.
- `OpenYoinkTests/TestKit/Shelf/ShelfScenarioTests.swift`: behavioral checks using the same fixtures.
- `OpenYoinkTests/Island/IslandModulePreviewTests.swift`: export orchestration and remaining module catalogs.
- `Scripts/render-module-previews.py`: CLI and external macOS screenshot worker.

To add a Shelf scenario, give its enum case an explicit stable ID, add a label, and prepare its state in `ShelfScenarioFixture`. Keep data generation in `ShelfFixtures`. The catalog automatically discovers all enum cases. View creation happens after filtering, once per captured Shelf scenario. Add behavioral assertions separately when the scenario exercises a rule, rather than asserting only that a screenshot exists.

Example: `--module shelf --scenario expanded-stack` produces `shelf-expanded-stack-regular.png` and `shelf-expanded-stack-extended.png`. Modules that support extension (Shelf and Quick Settings) automatically capture both height modes. Manifest entries contain the capture `id`, stable `scenarioID`, `scenario` label, `heightMode`, and measured dimensions. Other modules retain label-derived IDs until migrated.

Shelf generates six real sample files/folders in a fresh `/tmp/openyoink-sample-files-*` directory: two PNG illustrations, a formatted RTF brief, TXT meeting notes, a CSV budget, and a folder containing palette notes. Their locations appear in the runner output and `samples.json`; you can drag these files into the app manually. They contain only synthetic data. One deliberately missing document remains to exercise recovery UI. Samples are disposable and retained for manual testing; remove their directory when finished. All rendered screens use current app components. Capture success validates export, not visual correctness; there are no automatic pixel baselines.

The live app and previews now share `IslandModuleHost`, including extension bindings and content-height reporting. Preview windows use the production coordinator, `IslandExpandedSurface`, and geometry resolver, with a fixed 1512×982 notched-screen fixture. Extended height follows measured content and the same screen cap as the app; short states can remain the same height. The shortcut navigation band is still reserved rather than rendered, and previews do not simulate the live controller's drag/hover/window lifecycle.

The large-grid scenario uses 40 independently generated files/folders with different project content, and the long-name scenario uses eight additional unique files with long filenames. These live in `Project collection` and `Long filenames` beneath the sample directory. Inline text cards are isolated in the explicitly labeled `text-snippets` scenario.

Collection artwork includes maps, landscapes, star charts, charts, and portrait posters. Documents contain project-specific briefs, checklists, planning notes, budgets, and reference packs. A content-hash regression test rejects duplicate payloads across all 48 collection entries.
