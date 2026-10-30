# Log storage and filtering

The approved log-viewer handover calls for daily files and an in-app viewer.
This first stage builds the independent file and filtering code. App integration
waits until PR #49 (Settings) and PR #51 (Teams logging) merge.

## Agreed decisions

- Use #49's `OrdinaryWindowActivation` and production-only `AppLaunchMode` wiring.
- Reuse #51's `Log`, categories, and `LogMessage` privacy interpolation. Do not
  create competing definitions here. Private values become `<private>` before
  either output sees text. Error descriptions need a source review before they
  can be public; prefer a fixed message and an error code.
- Create the log directory with 0700 permissions and files with 0600.
- Keep the proposed categories: app, capture, tiling, hotkeys, permissions,
  keepAwake, clipboard, meeting, teams. Levels are info, notice, error.
- Use TDD for formatting, file behavior, and filtering.

## Approach

Read daily files for the viewer. Reading macOS unified logs would not supply
the specified retention or reliably include info messages. A second logging
framework would duplicate #51's privacy handling. The file writer therefore
accepts only text that the caller has already redacted.

`LogLine` formats and parses
`2026-10-30 13:08:07.195 +0200 [21621] notice teams: message`.
Escape every Foundation newline character as literal `\n`, with CRLF counted
as one break. This includes CR, LF, U+2028, U+2029, U+0085, vertical tab, and form
feed. Limit the normalized message
to 2,000 Swift characters followed by an ellipsis if cut. Preserve Unicode
characters. Parse timestamps with their offsets; compare actual dates, not
display strings, across daylight saving changes. Categories remain strings
so adding a category in `Log.swift` needs no change here.

`LogFiles` takes an explicit folder and clock. It never selects the real user
folder or starts at app launch itself. It schedules work on a private serial
queue. Each append opens the daily file with append mode, writes the complete
UTF-8 line in one write, and closes it. Errors reach an injected handler, never
the logger itself. Deletion runs on the same queue and can report failure.

Daily names are `Ku-Ka-YYYY-MM-DD.log`, based on the line's local date. At
startup and on the first append for a new day, remove files dated more than
14 calendar days before today. Then remove the oldest files until their total
size is at most 20,000,000 bytes, keeping today's file even if it exceeds the
cap. Only strictly named regular files belong to this store. Other files,
directories, and symlinks stay unchanged. Delete All removes owned files;
the next append recreates today's file. Tests use temporary folders only.

`LogFilter` consumes rows with their source-file date. Ranges are This launch,
Today, Last 7 days (today and the previous six calendar days), and Everything
kept. This launch requires both matching PID and timestamp at or after launch.
Unknown-format rows remain visible under All categories for date-based ranges,
but cannot prove launch membership or an error level. Filter before retaining
the newest 5,000 rows. Return rows oldest first, using parsed absolute time and
stable input order for ties; unknown-format rows keep their place in input.

## Deferred work

After both PRs merge: connect both logging outputs, add a cached background
`LogReading` adapter, the two-second refresh, window controls and follow behavior,
menu action, production startup, and migration of the 37 NSLog calls. Test
privacy at the two-output boundary then. Document shipped UI only when it exists.
