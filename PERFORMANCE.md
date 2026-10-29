# Openly 0.2 performance and validation

## Artifact size

Compared 0.1.0 source with the final 0.2.0 build including batch selection on the same Apple Silicon Mac. Apple Swift 6.4, macOS 27 SDK, deployment target macOS 13. These are file bytes, not filesystem allocation sizes.

| Item | 0.1.0 | 0.2.0 | Reduction |
| --- | ---: | ---: | ---: |
| App file bytes (excluding filesystem attributes) | 1,093,864 B | 453,920 B | 58.5% |
| Executable | 785,904 B | 364,272 B | 53.6% |
| App icon | 303,365 B | 85,053 B | 72.0% |
| ZIP | 478,011 B | 197,966 B | 58.6% |

The build uses -Osize, whole-module optimization, dead stripping, and symbol stripping. Icon generation uses explicitly sized 8-bit RGBA bitmaps while keeping the required icon resolutions. No third-party runtime was added.

## Runtime budgets and observations

Application candidates load only when a menu opens. The model reuses 64x64 color thumbnails with NSCache budgets of 32 images / 512 KiB and 128 names. Unchanged defaults do not republish the list; mutations verify only affected types. There is no disk thumbnail cache, background service, or polling timer. NSCache budgets are managed by the system and are not a hard cap on process memory.

Development footprint samples: 0.1.0 approximately 36.1 MB at startup and 55.1 MB after interactions; an intermediate optimized build before batch UI approximately 38.3 MB and 49.8 MB. Window size, timing, and user actions were not strictly isolated. These samples are NOT a controlled benchmark of the final batch build and do not prove a fixed reduction. Startup memory did not demonstrably decrease. RSS, physical footprint, and peak footprint are different measurements.

## Validation

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
