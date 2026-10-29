# Calendar reminder synthetic evidence

`CalendarNativeTests.testSyntheticBeforeAfterEvidenceUsesRealRequestsAndGeneratedDocuments` creates actual `UNNotificationRequest` values through an injected center and writes real summary and transcript files in a temporary meeting folder. Its retained XCTest attachment is named `calendar-reminder-synthetic-evidence`. These are request and document values, not native banner screenshots.

## Requests

Before the feature, Ku-Ka had no calendar requests or categories. The red adapter run returned no request. After implementation, the captured Start request contains these values.

```text
Identifier: calendar-recording.11111111-1111-1111-1111-111111111111
Category: calendar-recording.start
Title: Planning
Body: Record this calendar meeting?
User info: calendarToken = 11111111-1111-1111-1111-111111111111
Trigger: nil
Action: Start Recording
```

The captured End request contains these values.

```text
Identifier: calendar-recording.22222222-2222-2222-2222-222222222222
Category: calendar-recording.end
Title: Planning
Body: The calendar meeting has ended.
User info: calendarToken = 22222222-2222-2222-2222-222222222222
Trigger: nil
Actions: Stop Recording, Continue Recording
```

The native request test asserts categories, action labels, immediate triggers, and token-only data. A default Start click decodes to dismissal. A default End click shows the controls. Unknown actions and malformed tokens have no calendar action.

## Recording menu

The unchanged manual recording test asserts `● Recording · 0:00`. The new title test asserts `● Recording · 0:00 · Planning`, then `Paused · 0:10 · Planning` after ten synthetic seconds. The long-title test asserts a 48-character suffix ending in an ellipsis, with all 120 title characters in its tooltip and accessibility label. No live menu was opened through UI automation.

## Generated notes

Before title metadata is set, the generated summary is:

```markdown
# Meeting on 2026-10-23 at 14:02

Ship on Friday.
```

After `saveDisplayTitle("Planning")`, the written summary is:

```markdown
# Planning

Ship on Friday.
```

The written transcript starts with `# Planning`, reports `Duration: 00:01:00`, and names `Synthetic` as its transcriber. Empty synthetic segments produce `No speech was detected.` The dated folder name is unchanged. Existing title tests cover reconstruction, Markdown escaping, and keeping the heading out of spoken summary content. No model, CLI, private transcript, or capture was used.

## Pending native checks

Native banners and VoiceOver require actual notification delivery and remain unverified. Calendar grants, real recurrence and provider behavior, sleep and wake, and the sibling Settings UI remain manual checks. Fixtures do not prove these platform behaviors.
