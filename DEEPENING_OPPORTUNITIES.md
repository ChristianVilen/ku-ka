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

## 5. StatusMenu — UI construction out of AppDelegate — ✅ DONE (2026-08-10)

**Implemented**: `StatusMenu.swift` (170 lines) owns the menu-bar menu end to end: it builds the structure, owns the five action handlers (writing through `Settings`), keeps checkmarks in step, embeds the keep-awake section, serves as the menu's delegate (forwarding open/close to `KeepAwakeController`), and renders the status-item icon via `icon(keepAwakeActive:)`. The split went deeper than the original state-in/menu-out sketch — owning the handlers deleted them from AppDelegate entirely. `StatusMenuTests` (5 tests) asserts structure, toggle behaviour through a scratch-defaults `Settings`, exclusive duration selection, the login seam, and the badge.

---

## 6. Settings — typed preferences, injected defaults — ✅ DONE (2026-08-10)

**Implemented**: `Settings.swift` (52 lines) holds `thumbnailDuration`, `windowTilingEnabled`, and launch-at-login as typed properties — every key and default defined once. Launch-at-login sits behind a `LoginItemManaging` seam (`SystemLoginItem` wraps `SMAppService`), so it finally has a test surface. `CaptureFlow`'s duration default now reads `Settings()` — the `"thumbnailDuration"` string exists in exactly one production file. `SettingsTests` (4 tests) uses a scratch `UserDefaults` suite and a fake login item, including the registration-failure path.

---

## 7. StageManagerDetector — the seam costs more than the behaviour

**Strength**: Speculative (awareness item, not a task)

**Files**: `StageManagerDetector.swift` (14 lines)

**Problem**: A 1-property protocol, an adapter, and a mock wrap a single `UserDefaults` read. The interface costs more lines than the implementation behind it — the inverse of deep.

**Solution**: Leave it; it is the price of testing `WindowTilingController`. If a second macOS-environment probe ever appears, widen this into one `DesktopEnvironment` interface rather than adding another ceremony seam.

---

## Top recommendation

Candidates 1, 2, 3, 5, and 6 are all done (2026-08-10). AppDelegate is 110 lines of construction and wiring — down from 357 when this review started. The one remaining refactor is the **Screens seam** (candidate 4): mop up the ambient `NSScreen` reads the finished refactors deliberately left behind, delete the test-suite `XCTSkipIf`, and kill the headless `NSScreen.main!` crash. Candidate 7 (StageManagerDetector) stays an awareness item.
