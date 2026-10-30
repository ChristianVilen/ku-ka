# Best-effort Teams speaker names

## Authorization and outcome

On 2026-10-29 the user authorized implementation without proving live Teams compatibility. This supersedes the earlier requirement to wait for a real call before design. No suitable call is active. Do not inspect Teams or start a recording during this work.

When the user enables `teamsSpeakerNamesEnabled`, collect Teams desktop speaker observations during recording. After Stop, name a system-audio segment only when conservative evidence supports one participant. Otherwise keep `Them`. Preserve microphone Room labels, the live draft, and all existing meeting processing behavior.

The setting defaults to false. It is read once for each recording. Task #43 owns its persistent Settings control. This branch supplies the Settings property and documents a `defaults` command. It adds no menu toggle or Settings window. Do not change the user's real defaults.

## Approaches and synthesis

Two independent designs compared recorder-owned observation history with online interval construction and a shared folder-keyed store. An independent judge preferred the immutable handoff. Both candidates converged on that ownership model. Use candidate A's named value boundary and candidate B's conversion at Stop, explicit run identity, delayed-result rejection, and folder-based queue deduplication.

The parent chose this design under the user's delegation of implementation choices. A shared store would require cleanup and lookup rules in several owners. Instead, one recording owns its history, and one queued job owns the resulting immutable evidence. Lost evidence on quit, crash, or a later retry means `Them`. Already written labels survive Update Notes through the heard transcript.

## Data and interfaces

`TeamsSpeakerName` is a validated display name with a read-only `value`. Reject empty names, control characters, newlines, markup delimiters `*`, `[`, `]`, backslash, backtick, `<`, and `>`, reserved labels `Me`, `Them`, and `Room N`, and names over 80 characters or 256 UTF-8 bytes. Keep normal Unicode names, spaces, apostrophes, hyphens, and parentheses. Do not correct or infer names through known words.

`TeamsSpeakerObservation` contains scan start/end `HostTime`, a sequence number, a source-context identifier, and an optional `TeamsSpeakerName`. Nil means unavailable, silent, overlapping, or otherwise uncertain. These are observations, not voice identities. The source-context identifier is session-local and never persisted.

`TeamsSpeakerHistory` is a pure bounded value. `append(_:runID:)` records observations for one stream run and reports whether collection can continue. `finish(clock:endingAt:)` returns immutable `TeamsSpeakerEvidence`. The evidence supplies `name(for: TranscriptSegment)` and `.empty`.

`TeamsSpeakerObserving.observations()` returns an `AsyncStream<TeamsSpeakerObservation>`. It starts no work before this method is called. The real implementation polls on a serial utility task, never the main actor. Stream cancellation ends polling. Buffering is bounded and sequence gaps break continuity.

`RecordedMeeting` contains `folder: MeetingFolder` and `speakers: TeamsSpeakerEvidence`. `MeetingRecorder.onEnded` passes this value. `MeetingNotesController.Job.process` holds it. `MeetingProcessor.process(_:speakers:progress:)` accepts evidence with an empty default. Deduplication compares operation and folder, never observations. Recovery and Retry use empty evidence.

`Speaker.teams(TeamsSpeakerName)` has system track and renders `Name (Teams)`. `Transcript.merge(_:rooms:joinGap:speakers:)` assigns system names before joining, with empty evidence as the default. Microphone echo filtering continues to use original system segments. Add new speaker legends without changing historical legends. `contentForSummary`, known-word correction, and quote placement must accept named labels.

## Timing and conservative matching

These are design choices, not measured accuracy thresholds:

- Poll no faster than every 300 ms. A valid scan lasts at most 150 ms.
- Keep at most 36,000 observations. Stop collection at the cap and retain earlier evidence.
- Positive evidence lies only between the end of one scan and the start of the next. Both scans must name the same participant in the same source and run, with consecutive sequence numbers and a gap no greater than 750 ms.
- Never extrapolate before the first scan or after the last. Invalid or out-of-order observations break continuity.
- Map host intervals with the final `RecordingClock`. Reject any interval that crosses a pause boundary, even if both endpoints map. Leave the three-second resume gap empty. Exclude observations after Stop. The clock alone interprets pauses: `fileIntervalInOneRun(from:to:)` maps a scan or a positive span only inside one recording run, and `keptFileIntervals(from:to:)` clips an uncertain observation, a point included, to the kept runs. Teams code never reads the clock's pause and resume times.
- A name needs at least 90% coverage of a segment, no positive evidence of another name, no explicit uncertain observation within that segment, and no uncovered gap longer than 750 ms. Unknown, overlapping, invalid, or zero-duration segments keep `Them`. Never split text without word times.

The recorder owns a per-recording collection object outside equatable panel state. It owns the history and consumer task, so samples do not refresh the UI. Pause cancels its current run. Resume starts a fresh run with a new identity and host-time lower bound. Drop delayed results from old runs. Stop and interruption freeze evidence and cancel before handoff. Quit and deinit cancel and discard. Failed or cancelled startup must not leave a source running. The recorder's private `.starting(id:)` state holds the identity of a start attempt, so no separate ID can outlive Starting. After each await, an obsolete start stops any capture handle it got and changes no state, alert, or observer.

## Read-only Teams adapter

The source baseline is [Thread's monitor](https://github.com/salesforce-misc/thread/blob/730cab97a3a32ffb48501527183e689c850d5c18/Thread/SpeakerVisionMonitor.swift) and [Anarlog's call-control checks](https://github.com/fastrepl/anarlog/blob/a7dadfbb9477177723cab1e140ae06b4e868ecc5/crates/detect/src/meeting_ax/node.rs). Reimplement the small necessary rules. Do not copy their broad scans or AX writes.

Target only `com.microsoft.teams2`. Check Accessibility trust without prompting on every scan. Require exactly one meeting window. Recognize a visible enabled `Hang up` or `Leave` button inside a visible enabled `AXToolbar` identified by `meeting-controls` or `calling-controls`, or labelled `Meeting controls` or `Calling controls`. Both the toolbar and button need finite positive bounds. Requiring toolbar ownership is a deliberate privacy restriction beyond the public source's broader call-control checks. These roles, identifiers, and English labels are compatibility limitations. A roster, window title, generic web area, or button outside that toolbar is insufficient.

Walk bounded structural metadata first. Read roles, identifiers, DOM classes, child relationships, bounds, and enabled state. Only read control labels for call controls, and name text in a structurally owned candidate participant tile. Exclude chat, caption, text-input, document, and shared-content branches before reading content. Unknown or ambiguous scope produces no name.

Thread's `frwhdur`, `f578s74`, `f4mjgsl`, `f1xul6tz`, `fj20gam`, and `f3ve9t9` are candidate border classes. Require at least two classes to nominate a marker. Do not use `vdi-frame-occlusion`, mute state, or roster order as speech evidence. The candidate must also have video-tile scope: the marker or its immediate same-bounds parent carries `vdi-frame-occlusion`. That token is only a structural hint, never a positive speaking signal. This deliberately narrow profile can miss other Teams layouts.

The tile must own exactly one name text node within its subtree. Do not choose a name from a nearby unrelated element. Reject self tiles, ambiguous names, multiple highlighted tiles, forbidden descendants, and unsupported structures. Nested marker elements for the same tile can be deduplicated by their common tile; distinct tiles remain ambiguous even when names match. Before reading a candidate name, reject tiles containing text inputs, caption/chat/document/shared-content metadata, or nested web areas. Do not recursively read all window text to discover tiles.

The bounded metadata traversal is the one place that decides ancestry. For each node it records the ownership facts it inherits from its ancestors (the shared bounds, whether the ancestor roles allow root ownership, self metadata, and the qualified toolbar) and its subtree range. Meeting-control and tile decisions use only these qualified references. The root, toolbar-interior, and tile-interior rules stay different on purpose. Marker tiles are counted before a tile is validated, so an invalid second marker still makes the result ambiguous.

Bound scans to 512 nodes, depth 16, 40 children per node, eight windows, and a 150 ms soft deadline. Set each AX message timeout to at most 50 ms or the remaining budget. Exceeding a limit or an unexpected AX failure invalidates the whole observation. Unsupported optional attributes and absent optional values are missing metadata, not transport failures; missing required evidence cannot produce a name. Read only candidate labels, each with a 256-byte content cap. AX can return more bytes than the output cap, so do not claim a hard IPC memory bound. No raw tree, labels, or observations go to logs or disk.

These selectors and the tile relationship are unverified assumptions. They can yield only `Them`, or misread a persistent last-speaker highlight. The feature is experimental and opt-in. Fake tests cannot validate Teams' actual UI semantics. Keep the diagnostic available for a later call.

## Summary ownership and privacy

Explain that `(Teams)` labels come from best-effort meeting UI observations. A label alone does not prove action ownership. Retain the rule that the transcript must say who will do the task, otherwise use `Unclear`. Do not allow speaker labels, a roster, calendar, context, or voice guesses to supply an owner without that evidence.

Raw observations stay in memory and disappear when their job completes. Only names supported by matching enter the heard and final transcripts. Those labels then go to the summary CLI with the transcript. Preserve relevant-only known-word sharing, the full optional meeting context, CLI isolation, and audio disposal after the transcript exists.

## Verification and integration boundaries

Use fake AX, fake capture, temporary meeting folders, and isolated defaults. Use `build/task-verification` for Xcode. Prove pure attribution, boundary failures, source cleanup, pause mapping, stale callbacks, queue delay, recovery fallback, named transcript formatting, room/echo preservation, and summary rules with TDD. Capture before/after transcript output from synthetic data. There is no new app UI to screenshot.

Shared changes are limited to `Speaker`, recorder handoff and starting state, the `RecordingClock` interval API, processing job payload, processor merge argument, Settings property, and AppDelegate injection. Task #43 consumes `Settings.teamsSpeakerNamesEnabled`; it owns the control. Task #28 keeps calendar association separate. When the branches combine, its existing recorder Session ID becomes the payload of `.starting`; do not add a second startup ID. Task #27 remains remote diarization. Do not merge sibling branches or change other checkouts.

## Implementation reconciliation

The parent accepted a narrower toolbar scope for call controls and an explicit video-frame scope for candidate tile text. They prevent broad label reads and may miss supported Teams layouts. The native adapter treats unsupported optional AX attributes as absent while unexpected errors invalidate the scan. These changes preserve the evidence and queue interfaces. Live Teams verification remains open, by user authorization, rather than a prerequisite for implementing this design.

A later structural review ([plan](../plans/2026-10-29-teams-judo-fixes.md)) changed only where three rules live. The AX traversal holds ancestry in one place, the recording clock alone projects host intervals, and the starting state owns the startup identity. Selectors, limits, thresholds, labels, and transcript output did not change.
