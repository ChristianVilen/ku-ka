# Deepening Opportunities

Architectural candidates for refactoring Ku-Ka toward deeper modules with better testability and locality.

Reviewed 2026-08-10, replacing the earlier version. Since then, window tiling landed and became the in-repo reference pattern: `WindowTilingController.tile()` is one method over four injected adapters — decisions returned as data, effects behind protocols — and it has 237 test lines to show for it (still growing: the screen-hop and center actions landed with tests attached). Every candidate below is "make the capture side look like the tiling side." About 45% of production code (~1,050 lines) has no test surface, almost all of it in the capture flow and AppDelegate.

---

## 1. SelectionSession — the overlay + selection lifecycle has no module — ✅ DONE (2026-08-10)

**Implemented**: `SelectionSession.swift` now owns the lifecycle behind `run(on:mouseLocation:) async -> SelectionResult`. Overlay creation, key-window election, teardown, and cancellation are implementation; the production `OverlayPresenter` adapter sits at an internal `OverlayPresenting` seam, and `SelectionSessionTests` (11 tests) covers election, screen attribution, teardown-before-resume, resume-once, and re-entrancy. The `.window` result now carries the screen with the largest overlap of the window's frame (fixes the multi-display thumbnail-placement bug; falls back to the overlay's screen). AppDelegate dropped from 357 to 313 lines and never touches an overlay.

---

## 2. CaptureFlow — collapse the capture pipeline — ✅ DONE (2026-08-10)

**Implemented**: `CaptureFlow.swift` owns the pipeline behind `start(_ mode: .interactive | .fullScreen, screens:mouseLocation:)`. The fullscreen path moved in too. Dependencies sit at three test-seam protocols (`SelectionRunning`, `CaptureProviding`, `ThumbnailPresenting`) satisfied by the concrete classes via empty extensions; the thumbnail-duration read, flash, and 50 ms settle delay are injected with production defaults. `CaptureFlowTests` (8 tests) covers both paths, failed captures, flash-only-on-fullscreen, and the duration seam. AppDelegate's hotkey dispatch is one line per case and the old `startCapture`/`startFullScreenCapture`/`captureAndShow`/`showThumbnail` are deleted (313 → 287 lines). Known edge accepted: fullscreen with the mouse on no screen now falls back to the first screen instead of `NSScreen.main`.

---

## 3. ImageStore — persistence out of CaptureManager — ✅ DONE (2026-08-10)

**Implemented**: `ImageStore.swift` owns everything that happens to a produced image behind the `ImageStoring` seam: `store(cgImage:)` (the old `finalize`), `storeCombined(top:bottom:)`, `saveAnnotated(image:to:)`, `delete(at:)` — plus disk writes, clipboard policy, file naming, the Screenshots directory, and `MemoryReclaim`. The split went deep: `CaptureManager` is now pure capture (`init(screenCapture:store:)`, three methods, 141 lines — was 304) and hands every fresh CGImage to the store. `ThumbnailStackManager(store:)` and `EditorWindow(image:fileURL:store:)` receive the store directly — the function-valued `onCombine`, `onDelete`, `onStackEmptied`, `onSave`, and editor `onDelete` callbacks are all deleted; `onEdit` and `onClose` (genuine UI events) survive. The ~140 lines of persistence tests moved to `ImageStoreTests` with only construction changes; the seam is covered by delegation tests, stack tests through a `FakeImageStore`, and new `EditorWindowTests`.

---

## 4. A Screens seam — stop reading NSScreen from the air

**Strength**: Strong

**Files**: `CaptureManager.swift:101`, `ThumbnailStackManager.swift:94`, `WindowTilingController.swift:32, 76`, `EditorWindow.swift:15`, `AccessibilityWindowControl.swift:213`, `WindowListProvider.swift:18`, `ScreenCoordinates.swift`

**Problem**: Six modules read `NSScreen.screens` / `NSScreen.main` ambiently instead of receiving screens as a dependency. Standouts:

- `CaptureManager.captureFullScreen(screen:)` takes a screen argument and *still* reads `NSScreen.screens[0]` (`CaptureManager.swift:101`).
- `ThumbnailStackManager.swift:94` force-unwraps `NSScreen.main!` — crashes headless.
- The cost shows up in the tests: `WindowTilingControllerTests.swift:14` opens with `XCTSkipIf(NSScreen.screens.isEmpty)`.

Related: coordinate flipping is hand-rolled four different ways in three files (`CaptureManager.swift:164-169` flips against the primary screen, `:189-194` against the local screen — different rules in adjacent methods; `:74-79` subtracts the display origin again in the adapter; `SelectionView.swift:155-160` has a fourth). `ScreenCoordinates.flipVertical` — the module built exactly for this — is used only by the tiling side.

**Solution**: A `Screens` protocol (all / main / primary) with a system adapter and a test adapter, injected the same way as the app's existing seams (`SleepPreventing`, `WindowControlling`). Deepen `ScreenCoordinates` to own every conversion, so `CaptureManager` never mentions `NSScreen` at all.

**Benefits**: Deletes the `XCTSkipIf` — the suite runs headless. Multi-display behaviour becomes testable across four modules at once. Kills the `NSScreen.main!` crash. Locality: one flip rule, one place.

---

## 5. StatusMenu — UI construction out of AppDelegate

**Strength**: Worth exploring

**Files**: `AppDelegate.swift:40-121` (menu build), `AppDelegate.swift:239-270` (badge drawing)

**Problem**: The single largest block in AppDelegate (82 lines) builds the status-bar menu with imperative `NSMenuItem` calls; 31 more lines compose the status-item icon badge with Core Graphics. Neither is orchestration nor wiring — it is UI construction living in the app delegate. With the capture flow and persistence wiring extracted, this is most of the 270 lines AppDelegate has left.

**Solution**: Extract a `StatusMenu` module that builds the menu and renders the icon from passed-in state — state in, `NSMenu`/`NSImage` out. Returns results, no side effects.

**Benefits**: AppDelegate drops to roughly 240 lines before the other candidates land. Menu structure becomes assertable without a running app. Mechanical: low risk, no seam decisions to make.

---

## 6. Settings — typed preferences, injected defaults

**Strength**: Worth exploring

**Files**: `AppDelegate.swift:53, 67, 187, 213-218, 226-237`, `CaptureFlow.swift:43-45`; pattern to copy: `KeepAwakeController.swift:40`

**Problem**: Three preference keys are read/written ambiently: `"thumbnailDuration"` (string key ×3 — two in AppDelegate, one as CaptureFlow's injected default — default `5.0` ×2), `"windowTilingEnabled"` (`?? true` duplicated), and launch-at-login against the `SMAppService.mainApp` singleton (read ×3, untestable). A `Settings` module replaces CaptureFlow's duration default in one line. The good pattern already exists in this codebase — `KeepAwakeController` takes `defaults: UserDefaults = .standard` as an injected dependency, which is what lets its tests use a scratch suite. AppDelegate doesn't use it.

**Solution**: A `Settings` module with typed properties (`thumbnailDuration`, `windowTilingEnabled`, `launchAtLogin`), keys and defaults defined once, `UserDefaults` and `SMAppService` as implementation.

**Benefits**: Keys and defaults defined once. Launch-at-login gets a test surface. Small change; the injection pattern is already proven in-repo.

**Note**: the earlier version of this candidate claimed `ThumbnailStackManager` reads `UserDefaults` directly. That was wrong — it already takes `duration:` as a parameter, and its timer behaviour is already tested. The candidate survives on the evidence above instead.

---

## 7. StageManagerDetector — the seam costs more than the behaviour

**Strength**: Speculative (awareness item, not a task)

**Files**: `StageManagerDetector.swift` (14 lines)

**Problem**: A 1-property protocol, an adapter, and a mock wrap a single `UserDefaults` read. The interface costs more lines than the implementation behind it — the inverse of deep.

**Solution**: Leave it; it is the price of testing `WindowTilingController`. If a second macOS-environment probe ever appears, widen this into one `DesktopEnvironment` interface rather than adding another ceremony seam.

---

## Top recommendation

~~SelectionSession~~, ~~CaptureFlow~~, and ~~ImageStore~~ — all done 2026-08-10. Next up: **Screens seam** (candidate 4) — mops up the ambient `NSScreen` reads the finished refactors deliberately left behind, deletes the test-suite `XCTSkipIf`, and kills the headless `NSScreen.main!` crash. **StatusMenu** (candidate 5) and **Settings** (candidate 6) remain as smaller follow-ups.
