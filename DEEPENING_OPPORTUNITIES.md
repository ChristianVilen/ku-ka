# Deepening Opportunities

Architectural candidates for refactoring Ku-Ka toward deeper modules with better testability and locality.

Reviewed 2026-08-10, replacing the earlier version. Since then, window tiling landed and became the in-repo reference pattern: `WindowTilingController.tile()` is one method over four injected adapters — decisions returned as data, effects behind protocols — and it has 237 test lines to show for it (still growing: the screen-hop and center actions landed with tests attached). Every candidate below is "make the capture side look like the tiling side." About 45% of production code (~1,050 lines) has no test surface, almost all of it in the capture flow and AppDelegate.

---

## 1. SelectionSession — the overlay + selection lifecycle has no module — ✅ DONE (2026-08-10)

**Implemented**: `SelectionSession.swift` now owns the lifecycle behind `run(on:mouseLocation:) async -> SelectionResult`. Overlay creation, key-window election, teardown, and cancellation are implementation; the production `OverlayPresenter` adapter sits at an internal `OverlayPresenting` seam, and `SelectionSessionTests` (11 tests) covers election, screen attribution, teardown-before-resume, resume-once, and re-entrancy. The `.window` result now carries the screen with the largest overlap of the window's frame (fixes the multi-display thumbnail-placement bug; falls back to the overlay's screen). AppDelegate dropped from 357 to 313 lines and never touches an overlay.

---

## 2. CaptureFlow — collapse the 11-hop capture pipeline

**Strength**: Strong (SelectionSession is done, so this is now mostly mechanical)

**Files**: `AppDelegate.swift:142-174, 197-199`

**Problem**: With SelectionSession extracted, the remaining orchestration in AppDelegate is `startCapture` (result dispatch, `:142-157`), `startFullScreenCapture` (`:159-167`), `captureAndShow` (the 50 ms delay, `:169-174`), and `showThumbnail` (`:197-199`). Much smaller than before, but still zero test surface — AppDelegate is guarded out of test runs (`AppDelegate.swift:24-28`) — and there is still no named module representing "a capture flow".

**Solution**: Extract a `CaptureFlow` module: takes `SelectionSession`, `CaptureManager`, and `ThumbnailStackManager` as dependencies, exposes `start(mode: .area | .window | .fullscreen)`. AppDelegate keeps one line per hotkey case — exactly what it already does for tiling at `AppDelegate.swift:132`.

**Benefits**: The whole pipeline gets a test surface through one interface — a `FakeSelectionSession` at the now-existing seam makes the tests cheap. Locality: sequencing bugs concentrate in one module. Leverage: a future flow (screen recording, say) reuses the same seam.

**Note**: the screen-attribution bug this card used to carry was fixed inside SelectionSession (candidate 1).

---

## 3. ImageStore — persistence out of CaptureManager

**Strength**: Strong

**Files**: `CaptureManager.swift:215-287`, `ThumbnailStackManager.swift:6`, `AppDelegate.swift:222-235, 252-266`

**Problem**: `saveAnnotated` (`CaptureManager.swift:215`), `saveCombined` (`:260`), and `deleteScreenshot` (`:284`) sit behind a capture interface they never use — the tests prove it: ~140 lines of `CaptureManagerTests` exercise these paths through a `MockScreenCapture` that is never called. Worse, `ThumbnailStackManager` needs these operations but gets them as a function-valued callback routed through AppDelegate:

```swift
// ThumbnailStackManager.swift:6
var onCombine: ((NSImage, NSImage) -> CaptureResult?)?
```

A callback with a non-Void return type is a dependency wearing a callback's clothes. Five of the seven closures AppDelegate wires on `ThumbnailStackManager` and `EditorWindow` are one-line forwards into `captureManager`. `MemoryReclaim.schedule()` is called from 4 places across 2 files, every one a persistence/teardown moment.

**Solution**: Extract an `ImageStore` module — `save`, `saveAnnotated`, `saveCombined`, `delete` — and inject it into `ThumbnailStackManager` and `EditorWindow` directly. It becomes the one owner of the `MemoryReclaim` policy. `CaptureManager`'s interface sharpens to capture operations only (11 methods → ~5).

**Benefits**: The seam is real from day one — two production callers (`ThumbnailStackManager`, `EditorWindow`), not a hypothetical. Deletes five pass-through closures and the function-valued `onCombine`. Tests for annotate/combine/delete drop the unused mock. Locality: memory-reclaim policy in one place.

---

## 4. A Screens seam — stop reading NSScreen from the air

**Strength**: Strong

**Files**: `CaptureManager.swift:163`, `ThumbnailStackManager.swift:89`, `WindowTilingController.swift:32, 76`, `EditorWindow.swift:13`, `AccessibilityWindowControl.swift:213`, `WindowListProvider.swift:18`, `ScreenCoordinates.swift`

**Problem**: Six modules read `NSScreen.screens` / `NSScreen.main` ambiently instead of receiving screens as a dependency. Standouts:

- `CaptureManager.captureFullScreen(screen:)` takes a screen argument and *still* reads `NSScreen.screens[0]` (`CaptureManager.swift:163`).
- `ThumbnailStackManager.swift:89` force-unwraps `NSScreen.main!` — crashes headless.
- The cost shows up in the tests: `WindowTilingControllerTests.swift:14` opens with `XCTSkipIf(NSScreen.screens.isEmpty)`.

Related: coordinate flipping is hand-rolled four different ways in three files (`CaptureManager.swift:164-169` flips against the primary screen, `:189-194` against the local screen — different rules in adjacent methods; `:74-79` subtracts the display origin again in the adapter; `SelectionView.swift:155-160` has a fourth). `ScreenCoordinates.flipVertical` — the module built exactly for this — is used only by the tiling side.

**Solution**: A `Screens` protocol (all / main / primary) with a system adapter and a test adapter, injected the same way as the app's existing seams (`SleepPreventing`, `WindowControlling`). Deepen `ScreenCoordinates` to own every conversion, so `CaptureManager` never mentions `NSScreen` at all.

**Benefits**: Deletes the `XCTSkipIf` — the suite runs headless. Multi-display behaviour becomes testable across four modules at once. Kills the `NSScreen.main!` crash. Locality: one flip rule, one place.

---

## 5. StatusMenu — UI construction out of AppDelegate

**Strength**: Worth exploring

**Files**: `AppDelegate.swift:36-117` (menu build), `AppDelegate.swift:282-313` (badge drawing)

**Problem**: The single largest block in AppDelegate (82 lines) builds the status-bar menu with imperative `NSMenuItem` calls; 31 more lines compose the status-item icon badge with Core Graphics. Neither is orchestration nor wiring — it is UI construction living in the app delegate. Together with the capture flow this is why AppDelegate is 313 lines.

**Solution**: Extract a `StatusMenu` module that builds the menu and renders the icon from passed-in state — state in, `NSMenu`/`NSImage` out. Returns results, no side effects.

**Benefits**: AppDelegate drops to roughly 240 lines before the other candidates land. Menu structure becomes assertable without a running app. Mechanical: low risk, no seam decisions to make.

---

## 6. Settings — typed preferences, injected defaults

**Strength**: Worth exploring

**Files**: `AppDelegate.swift:49, 63, 198, 230, 256-261, 268-280`; pattern to copy: `KeepAwakeController.swift:40`

**Problem**: Three preference keys are read/written ambiently: `"thumbnailDuration"` (string key ×3, default `5.0` ×2), `"windowTilingEnabled"` (`?? true` duplicated), and launch-at-login against the `SMAppService.mainApp` singleton (read ×3, untestable). The good pattern already exists in this codebase — `KeepAwakeController` takes `defaults: UserDefaults = .standard` as an injected dependency, which is what lets its tests use a scratch suite. AppDelegate doesn't use it.

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

~~SelectionSession first~~ — done 2026-08-10. Next up: **CaptureFlow** (candidate 2, now mostly mechanical with the SelectionSession seam in place) or **ImageStore** (candidate 3, deletes five pass-through closures and un-warps a callback that returns a value). Either order works; CaptureFlow finishes what candidate 1 started, ImageStore is independent of it.
