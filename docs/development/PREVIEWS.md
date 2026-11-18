# Module previews

Run from any directory. Fixtures render the actual module views with isolated sample stores and preferences; they do not change your Shelf contents.

```sh
# Every module and scenario, with the gallery opened afterward
Scripts/render-module-previews.sh

# Discover available scenarios (no image rendering)
Scripts/render-module-previews.sh --list
Scripts/render-module-previews.sh --module shelf --list

# Capture several matching scenarios; repeated filters are combined with OR
Scripts/render-module-previews.sh --module shelf --scenario duplicate --scenario file-drag

# Multiple modules, offscreen capture, no browser
Scripts/render-module-previews.sh --module shelf --module battery --capture snapshot --no-open

# Pick the destination
Scripts/render-module-previews.sh --module shelf --output /tmp/my-shelf-previews
```

Module slugs: `battery`, `timer`, `now-playing`, `ai-usage`, `clipboard`, `quick-access`, `shelf`, `transfers`, `system-status`, `quick-settings`.

`--scenario` matches case-insensitive substrings of scenario IDs or labels. Shelf IDs are stable even when their display labels change. A filter with no matches fails rather than silently producing an empty gallery. `--list` still builds and runs the fixture catalog so its labels stay in sync with the code.

The default `window` capture briefly displays each preview window and captures it with macOS's compositor, preserving blur and material backgrounds. Screen Recording permission may be required for the invoking terminal/app. `snapshot` captures offscreen without that permission, but blur and translucent materials may be missing. Captures reserve the navigation band; they don't reproduce live shortcut controls or the live controller's drag detection. Static images do not demonstrate animation or scrolling.

Each run defaults to a new `/tmp/openyoink-previews-*` directory with `index.html`, paginated per-module contact sheets, named scenario PNGs, `manifest.json`, and `build.log`. Explicit output directories can retain older files; the manifest/gallery identify this run's results. One runner may execute at a time. The runner removes its temporary request configuration on exit.

Add Shelf cases to `ClerestoryTests/TestKit/Shelf/ShelfScenario.swift` using real state/store inputs. Other modules still use the compatibility adapter in `IslandModulePreviewTests.swift`. Enabled cases automatically appear in listing, filtering, the manifest, and the gallery. Shelf includes empty, populated, selected, search-empty, importing, duplicate-drop, file-drag, long-name, large-grid, and keyboard-focus samples.

## Test kit structure

- `ClerestoryTests/TestKit/ModuleScenario.swift`: lazy view factories, stable scenario IDs, and isolated preference lifetime.
- `ClerestoryTests/TestKit/ModulePreviewRenderer.swift`: shared Island outer layout, captures, contact sheets, filtering, and manifest generation.
- `ClerestoryTests/TestKit/Shelf/ShelfSampleFiles.swift`: reproducible synthetic document/artwork generator.
- `ClerestoryTests/TestKit/Shelf/ShelfFixtures.swift`: fresh reusable sample data with no dependency on user files.
- `ClerestoryTests/TestKit/Shelf/ShelfScenario.swift`: typed scenario catalog and inspectable store/interaction state.
- `ClerestoryTests/TestKit/Shelf/ShelfScenarioTests.swift`: behavioral checks using the same fixtures.
- `ClerestoryTests/Island/IslandModulePreviewTests.swift`: export orchestration and remaining module catalogs.
- `Scripts/render-module-previews.py`: CLI and external macOS screenshot worker.

To add a Shelf scenario, give its enum case an explicit stable ID, add a label, and prepare its state in `ShelfScenarioFixture`. Keep data generation in `ShelfFixtures`. The catalog uses `ShelfScenario.previewCases`; stack cases are retained but excluded while stacks are disabled. View creation happens after filtering, once per captured Shelf scenario. Add behavioral assertions separately when the scenario exercises a rule, rather than asserting only that a screenshot exists.

Example: `--module shelf --scenario populated` produces `shelf-populated-regular.png` and `shelf-populated-extended.png`. Modules that support extension (Shelf and Quick Settings) automatically capture both height modes. Manifest entries contain the capture `id`, stable `scenarioID`, `scenario` label, `heightMode`, and measured dimensions. Other modules retain label-derived IDs until migrated.

Shelf generates six real sample files/folders in a fresh `openyoink-sample-files-*` directory under the test process’s temporary directory: two PNG illustrations, a formatted RTF brief, TXT meeting notes, a CSV budget, and a folder containing palette notes. Their locations appear in the runner output and `samples.json`; you can drag these files into the app manually. They contain only synthetic data. One deliberately missing document remains to exercise recovery UI. Samples are disposable and retained for manual testing; remove their directory when finished. All rendered screens use current app components. Capture success validates export, not visual correctness; there are no automatic pixel baselines.

The live app and previews now share `IslandModuleHost`, including extension bindings and content-height reporting. Preview windows use the production coordinator, `IslandExpandedSurface`, and geometry resolver, with a fixed 1512×982 notched-screen fixture. Extended height follows measured content and the same screen cap as the app; short states can remain the same height. The shortcut navigation band is still reserved rather than rendered, and previews do not simulate the live controller's drag/hover/window lifecycle.

The large-grid scenario uses 40 independently generated files/folders with different project content, and the long-name scenario uses eight additional unique files with long filenames. These live in `Project collection` and `Long filenames` beneath the sample directory. Inline text cards are isolated in the explicitly labeled `text-snippets` scenario.

Collection artwork includes maps, landscapes, star charts, charts, and portrait posters. Documents contain project-specific briefs, checklists, planning notes, budgets, and reference packs. A content-hash regression test rejects duplicate payloads across all 48 collection entries.

`file-drag` captures the blue outline; `duplicate` captures the red outline during a duplicate drag. Both use `IslandDropOutline`, the same surface component as the live app, and the same `DropTargetState` instance as their Shelf content. Captures show the settled expanded state, not the drag approach/transition animation. The released-drop toast is captured separately as `notice-already-on-shelf`.

### Shelf feedback previews

The Shelf catalog also includes every `ShelfNoticeMessage`, copy/path/share/Finder success and partial-result messages, transfer progress and terminal states, recovery buttons, move/reorder hints, and duplicate-drag feedback. The file-area duplicate blur/overlay is retained behind `ShelfDuplicateFeedback.usesFileOverlay` (currently false); duplicate drags show the red outline; after release, skipped duplicates produce the detached toast (`notice-already-on-shelf`). Filter with `--scenario notice-`, `--scenario transfer-`, or `--scenario drag-`; omit filters for the complete Shelf gallery.

Notice wording is shared with the app, and count-based messages use the runtime formatters. Shelf notice captures include the detached pill below the Island, using the production pill and gap; the extra capture height does not change the module viewport. Expanded notice samples represent a pinned-open Island. At runtime, an unpinned Island queues notices until its closing animation completes, then starts their display timer. Once shown, reopening pushes the same toast below the expanded surface without hiding it or restarting that timer. Debug fixtures hold transient notices and transfer completion states visible without changing runtime dismissal timing. Transfer samples use the fixture item IDs so card badges match the status strip. Captures use the same module host in both regular and extended height modes. Recovery and sharing actions are represented visually; the capture does not invoke native file pickers, share panels, or modify files.

Large catalogs are split into contact sheets of at most 12 captures: `shelf.png`, `shelf-2.png`, and so on. The HTML gallery links every page, and the manifest retains every individual scenario image.

## Panel and Notch

See [Panel and Notch architecture](../PANEL_ARCHITECTURE.md) for the display and window behavior. Generate the Shelf and Quick Settings gallery from the current checkout:

```sh
Scripts/render-module-previews.sh --module shelf --module quick-settings \
  --capture snapshot --output /tmp/openyoink-unified-panel-review --no-open
```

Expanded presentation is identical on notched and notchless displays. The fixed notched-screen fixture affects placement and the height cap, not a different panel shape or shortcut layout.
