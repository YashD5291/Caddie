---
task: 260701-xbi
title: "CAL-03 — fire meeting record prompt a configurable lead time before start"
requirements: [CAL-03]
date: 2026-07-01
duration: ~6 min
commits:
  - daab96e: "feat(cal-03): add lead-time prompt helpers to GoogleCalendarEvent"
  - b86608d: "feat(cal-03): fire meeting prompt within configurable lead time"
  - 84b1b3a: "feat(cal-03): add prompt lead-time setting and update README"
key-files:
  modified:
    - Sources/Calendar/GoogleCalendarEvent.swift
    - Tests/GoogleCalendarEventTests.swift
    - Sources/Calendar/GoogleCalendarService.swift
    - Tests/GoogleCalendarServiceTests.swift
    - Sources/UI/Settings/SettingsView.swift
    - README.md
---

# Quick Task 260701-xbi: CAL-03 Pre-Meeting Prompt Lead Time Summary

Closed CAL-03: the single "record this meeting?" calendar prompt now fires a configurable lead time BEFORE a meeting starts (default 2 min) instead of at/after start, with a user-adjustable 1/2/5-minute Settings picker persisted in `UserDefaults`.

## What Changed

### Task 1 — Model helpers (TDD)
Added three pure, now-injectable helpers to `GoogleCalendarEvent`:
- `hasEnded(now:)` — `endDate != nil && now >= endDate`
- `startsWithin(_:now:)` — `startDate.timeIntervalSince(now) <= lead` (negative interval for already-started events counts as within)
- `shouldPrompt(leadTime:now:)` — `!hasEnded && startsWithin`

`shouldPrompt` is a strict superset of the old `isNow` (an in-progress, not-ended event still prompts). `isNow`/`isPast`/`isUpcoming` left untouched to minimize regression risk (approved decision). Six new deterministic tests using a fixed whole-second `now`.

### Task 2 — Service selection (TDD)
`checkActiveEvents(now: Date = Date())` now selects via `shouldPrompt(leadTime:now:)`, reading the lead time from `UserDefaults.standard.object(forKey: "meetingPromptLeadTimeSeconds") as? Double ?? 120` (object-check so an explicit 0 isn't masked). Preserved exactly: the `guard let onSignal` startup-window defer (does not consume `lastActiveEventID` when nil), once-per-event dedup, and the `stop()` deactivating signal. Four new tests (in-window fires once, out-of-window silent, raised persisted lead fires, dedup across repeated checks) plus the existing nil-onSignal and dismissed-event tests still pass.

### Task 3 — Settings picker + README
Added a "Prompt lead time" `Picker` (1 minute/2 minutes/5 minutes → 60/120/300s) to `generalSection`, `@State private var promptLeadTime = 120`, loaded in `.onAppear` and persisted via `.onChange` to the same literal key `meetingPromptLeadTimeSeconds`. README updated: Notify row + narrative describe the pre-meeting configurable prompt; "Pre-meeting notification" moved out of "Up Next" into "Recently Shipped (v2.0)".

## Verification
- `make test` printed `** TEST SUCCEEDED **` before every commit (RED confirmed before GREEN for Tasks 1 & 2).
- Key-string parity confirmed by grep: `meetingPromptLeadTimeSeconds` matches across `SettingsView.swift` (load + write) and `GoogleCalendarService.swift` (read).
- No second notification, no auto-start behavior, `stop()` semantics untouched. ROADMAP.md not modified.

## Deviations from Plan
None — plan executed exactly as written.

## Self-Check: PASSED
- Files verified present: GoogleCalendarEvent.swift, GoogleCalendarService.swift, SettingsView.swift, both test files, README.md, this SUMMARY.
- Commits verified in `git log`: daab96e, b86608d, 84b1b3a.
