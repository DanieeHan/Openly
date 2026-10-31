# Openly performance and validation

## 0.2.1 local verification (2026-11-01)

Built for arm64 / macOS 13 deployment target and tested on macOS 27.0.1. This is a local build; no new GitHub Release was published.

| Item | 0.2.1 |
| --- | ---: |
| App file bytes | 541,712 B |
| Executable | 452,064 B |
| ZIP | 241,728 B |

The recovery journal, batch results/retry, grouped undo, and termination protection add 87,792 bytes to the 0.2.0 app. These are file bytes, not filesystem allocation sizes. No runtime dependency or background service was added.

### Final-build memory samples

Measured the installed optimized build with `/usr/bin/footprint -p Openly --noCategories -f bytes`, using **phys_footprint**, not RSS. Same Mac, 800 × 560 pt dark window, 34 visible-list types, existing user history, no real association writes. Each startup sample was taken at a process age of about 5 seconds; the process was fully quit between runs. Caches were warm; these are not machine-reboot or cold-disk tests.

| Scenario | Physical footprint |
| --- | ---: |
| Fresh process 1 | 38,241,312 B |
| Fresh process 2 | 39,814,200 B |
| Fresh process 3 | 38,519,864 B |
| After selection, candidate menu, two-type no-op batch, result sheet and Shift/Cmd interactions | 47,203,360–47,219,744 B |
| Peak reported for that interaction run | 61,621,280 B |

The interaction range consists of three samples one second apart after returning to the main window. Startup median was approximately **38.52 MB** (decimal). This establishes an observed footprint for the final version; it does **not** establish a memory reduction against 0.2.0. The historical samples below used different windows and workflows. No memory cap or fixed reduction is promised.

### Validation

- `zsh test.sh`: model and lifecycle suites pass. Symbolic-link targets, broken links, invalid imports, migration of old link overrides, write-ahead records, per-item persistence, cancellation, stop/retry snapshots, complete failure details, batch undo, external-change protection, legacy history and 60-type batch retention are covered.
- Lifecycle tests compile the real `AppDelegate` and `AppModel`. A recording `NSApplication` confirms termination waits for the current callback and persisted outcome, replies exactly once, and prevents later batch writes. Single-operation and cancellation paths also pass. The association service and preferences are isolated replacements.
- Native UI: checkbox clicks toggle independently and accumulate; before/after screenshots show row positions unchanged; Shift selects four rows and Command removes one; applying the current TextEdit to TXT/RTF reports zero changed / two unchanged without opening a modal; the result sheet opens from the footer and closes normally.
- The tested installed executable matches the final source build byte-for-byte. The bundle passes strict ad-hoc signature verification. The version is 0.2.1 / build 3.
- No existing system defaults were modified by automated tests or the UI smoke test. Real authorization prompts, actual writes/undo across macOS versions, and Intel hardware remain outside this verification.

Reproduce the automated checks with `zsh test.sh`, build with `zsh build.sh`, then open the app and sample using the footprint command above. Keep the same window size, dataset and interactions when comparing versions.

## Historical 0.1.0 → 0.2.0 artifact size

Compared 0.1.0 source with the final 0.2.0 build including batch selection on the same Apple Silicon Mac. Apple Swift 6.4, macOS 27 SDK, deployment target macOS 13. These are file bytes, not filesystem allocation sizes.

| Item | 0.1.0 | 0.2.0 | Reduction |
| --- | ---: | ---: | ---: |
| App file bytes (excluding filesystem attributes) | 1,093,864 B | 453,920 B | 58.5% |
| Executable | 785,904 B | 364,272 B | 53.6% |
| App icon | 303,365 B | 85,053 B | 72.0% |
| ZIP | 478,011 B | 197,966 B | 58.6% |

The build uses -Osize, whole-module optimization, dead stripping, and symbol stripping. Icon generation uses explicitly sized 8-bit RGBA bitmaps while keeping the required icon resolutions. No third-party runtime was added.

## Runtime budgets and historical observations

Application candidates load only when a menu opens. The model reuses 64x64 color thumbnails with NSCache budgets of 32 images / 512 KiB and 128 names. Unchanged defaults do not republish the list; mutations verify only affected types. There is no disk thumbnail cache, background service, or polling timer. NSCache budgets are managed by the system and are not a hard cap on process memory.

Development footprint samples: 0.1.0 approximately 36.1 MB at startup and 55.1 MB after interactions; an intermediate optimized build before batch UI approximately 38.3 MB and 49.8 MB. Window size, timing, and user actions were not strictly isolated. These samples are NOT a controlled benchmark of the final batch build and do not prove a fixed reduction. Startup memory did not demonstrably decrease. RSS, physical footprint, and peak footprint are different measurements.

## Historical 0.2.0 validation

- zsh test.sh passes original functionality, refresh/query budgets, thumbnail reuse, Shift ranges/anchor, Command toggle, candidate intersection, deduplication, skip, partial failure, recovery history, concurrency, target snapshots, and hidden-selection protection. Real system defaults are only read by tests.
- Native UI: Shift selected four contiguous types, Command removed individual selections, common candidates appeared, and applying the current app to two types reported zero changes / two unchanged and cleared selection. No system defaults were changed by this UI smoke test.
- Other-app picker cancellation, invalid-extension error with preserved input, and history entry points passed.
- Modifier handling combines the current mouse event with global keyboard flags; injected event flags must not be discarded.
- Minimum 720pt layout checked. Dark contrast was source-reviewed; no global appearance setting was changed for automated testing.
- The build signs and strictly verifies the bundle in a temporary directory. The release ZIP is extracted and its signature and MIT license checked again before publication.

Reproduce:

```sh
zsh test.sh
zsh build.sh
stat -f '%z %N' dist/Openly.app/Contents/MacOS/Openly dist/Openly.zip
```

System framework caches, installed applications, macOS version, startup timing, and actual usage affect memory. No fixed process-memory figure is promised.
