# KuKa domain glossary

- **Capture** — producing a screenshot image from a screen region, window, or full screen, then saving it to disk and clipboard. Owned by `CaptureManager`.
- **Selection session** — one round of "user picks what to capture": overlays appear on every screen, the user drags a rect, picks a window (Space toggles window mode), or cancels (Esc). Ends with a single `SelectionResult` carrying the screen the capture belongs on. Owned by `SelectionSession`.
- **Thumbnail stack** — the pile of floating capture previews in the screen corner; entries can be edited, combined, deleted, or left to expire. Owned by `ThumbnailStackManager`.
- **Tiling** — moving the focused window to half/maximized/centered positions across screens via hotkeys. Owned by `WindowTilingController`.
- **Keep awake** — a timed session preventing system/display sleep. Owned by `WakeManager` / `KeepAwakeController`.
