---
phase: quick-260701-xbi
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - Sources/Calendar/GoogleCalendarEvent.swift
  - Tests/GoogleCalendarEventTests.swift
  - Sources/Calendar/GoogleCalendarService.swift
  - Tests/GoogleCalendarServiceTests.swift
  - Sources/UI/Settings/SettingsView.swift
  - README.md
autonomous: true
requirements: [CAL-03]

must_haves:
  truths:
    - "The 'record this meeting?' prompt fires when the event start is within a configurable lead time (default 2 min), not at start"
    - "Exactly one prompt fires per meeting (dedup unchanged via lastActiveEventID)"
    - "User can change the lead time (1/2/5 min) in Settings and it persists across launches"
    - "Events that ended never prompt; events dismissed never prompt; onSignal==nil startup window still defers exactly-once delivery; sign-out still emits the deactivating signal"
  artifacts:
    - path: "Sources/Calendar/GoogleCalendarEvent.swift"
      provides: "now-injectable pure helpers: hasEnded(now:), startsWithin(_:now:), shouldPrompt(leadTime:now:)"
      contains: "func shouldPrompt"
    - path: "Sources/Calendar/GoogleCalendarService.swift"
      provides: "checkActiveEvents selection using shouldPrompt + UserDefaults lead time, injectable now"
      contains: "shouldPrompt"
    - path: "Sources/UI/Settings/SettingsView.swift"
      provides: "lead-time Picker (1/2/5 min -> 60/120/300s) persisted to UserDefaults"
      contains: "meetingPromptLeadTimeSeconds"
  key_links:
    - from: "Sources/UI/Settings/SettingsView.swift"
      to: "UserDefaults meetingPromptLeadTimeSeconds"
      via: "Picker onChange write"
      pattern: "meetingPromptLeadTimeSeconds"
    - from: "Sources/Calendar/GoogleCalendarService.swift"
      to: "UserDefaults meetingPromptLeadTimeSeconds"
      via: "read inside checkActiveEvents"
      pattern: "meetingPromptLeadTimeSeconds"
    - from: "Sources/Calendar/GoogleCalendarService.swift"
      to: "GoogleCalendarEvent.shouldPrompt"
      via: "selection predicate in checkActiveEvents"
      pattern: "shouldPrompt"
---

<objective>
Fire the calendar "record this meeting?" prompt a configurable lead time BEFORE the meeting starts (default 2 min), instead of at the moment it starts. Add a Settings picker (1/2/5 min) persisted in UserDefaults, read directly by the GoogleCalendarService actor.

Purpose: Closes CAL-03 — the last open gap in the v2.0 milestone audit. The original requirement wanted a pre-meeting notification; the shipped behavior only prompted at/after start.
Output: Testable now-injectable model helpers, a lead-time-aware service selection, a Settings picker, and updated README.

Scope discipline (approved decisions — do NOT revisit):
- SINGLE actionable prompt, moved earlier. One notification per meeting. Do NOT add a second notification.
- Lead time picker options are exactly 1/2/5 min (60/120/300s), default 2 min (120s), persisted in UserDefaults key `meetingPromptLeadTimeSeconds`.
- Service reads UserDefaults directly inside checkActiveEvents (actor + UserDefaults is thread-safe). No new AppState wiring.
- Keep unchanged in spirit: once-per-event dedup, the onSignal==nil startup-window guard, and the stop() deactivating signal.
- Firing earlier does NOT auto-start recording (Record is user-initiated), so no pre-meeting silence risk.
</objective>

<context>
@.planning/v2.0-MILESTONE-AUDIT.md
@Sources/Calendar/GoogleCalendarEvent.swift
@Sources/Calendar/GoogleCalendarService.swift
@Sources/UI/Settings/SettingsView.swift
@Tests/GoogleCalendarEventTests.swift
@Tests/GoogleCalendarServiceTests.swift

<interfaces>
<!-- Key contracts the executor needs. Extracted from the codebase. Use directly. -->

GoogleCalendarEvent (Sources/Calendar/GoogleCalendarEvent.swift):
  var startDate: Date?   // nil for all-day events
  var endDate: Date?     // nil for all-day events
  var isNow: Bool        // now >= start && now < end  (KEEP UNTOUCHED)
  var isPast: Bool, isUpcoming: Bool, timeUntilStart: TimeInterval?

GoogleCalendarService (actor, Sources/Calendar/GoogleCalendarService.swift):
  func checkActiveEvents()   // currently selects: meetingEvents.first { $0.isNow && !dismissedEventIDs.contains($0.id) }
  // Signal firing: guard let onSignal else { return }  (do NOT consume lastActiveEventID when nil)
  //   if event.id != lastActiveEventID { lastActiveEventID = event.id; onSignal(DetectionSignal(source: .googleCalendar, ...isActive: true)) }
  //   else if lastActiveEventID != nil { lastActiveEventID = nil; onSignal?( ...isActive: false ) }
  #if DEBUG func injectCachedEvents(_:), func isDismissed(_:) -> Bool  // test seams
  static func filterMeetingEvents(_:) -> [GoogleCalendarEvent]  // attendeeCount >= 2, timed, not cancelled

Test seams available (GoogleCalendarServiceTests.swift):
  makeService(), makeTimedEvent(id:summary:start:end:attendees:), SignalBox (thread-safe collector)
  Pattern: await service.injectCachedEvents([...]); await service.setOnSignal { box.append($0) }; await service.checkActiveEvents()
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Add now-injectable prompt helpers to GoogleCalendarEvent (TDD)</name>
  <files>Sources/Calendar/GoogleCalendarEvent.swift, Tests/GoogleCalendarEventTests.swift</files>
  <behavior>
    Add three pure, deterministic helpers that take an injected `now: Date` (so tests don't depend on wall-clock):
    - `func hasEnded(now: Date) -> Bool` — guard endDate else return false; return now >= endDate
    - `func startsWithin(_ lead: TimeInterval, now: Date) -> Bool` — guard startDate else return false; return startDate.timeIntervalSince(now) <= lead  (secondsUntilStart may be negative for already-started events)
    - `func shouldPrompt(leadTime: TimeInterval, now: Date) -> Bool` — `!hasEnded(now: now) && startsWithin(leadTime, now: now)`

    Tests (add to GoogleCalendarEventTests.swift; use the existing `makeEvent(start:end:)` helper, pass an explicit `now`):
    - before window: start 300s after now, lead 120 -> shouldPrompt == false (startsWithin false)
    - inside window: start 90s after now, lead 120 -> shouldPrompt == true
    - boundary: start exactly 120s after now, lead 120 -> shouldPrompt == true (<= is inclusive)
    - already started, not ended: start 60s before now, end 600s after now, lead 120 -> shouldPrompt == true (superset of old isNow)
    - ended: end 60s before now -> hasEnded == true, shouldPrompt == false
    - startsWithin true but ended -> shouldPrompt == false (ended dominates)
    Also assert existing isNow behavior is unchanged (leave the isNow test cases passing).
  </behavior>
  <action>
    Write the failing tests FIRST (RED), run `make test` to confirm they fail to compile/pass, then add the three helpers to GoogleCalendarEvent below `timeUntilStart` (GREEN). Keep `isNow`/`isPast`/`isUpcoming` UNTOUCHED (approved decision — do not reimplement in terms of the new helpers; minimize regression risk). The existing `makeEvent` helper only takes start/end and hardcodes a JSON event — pass `now = Date()` at call sites and derive start/end relative to it so assertions are deterministic.
  </action>
  <verify>
    <automated>make test 2>&1 | tail -20</automated>
  </verify>
  <done>New helpers exist and are covered; all GoogleCalendarEventTests pass; isNow tests still pass. Commit: `test(cal-03): add lead-time prompt helpers to GoogleCalendarEvent` folded with `feat` per RED/GREEN — one atomic commit for the model helper. Commit message MUST NOT contain a Co-Authored-By line.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: checkActiveEvents uses lead time + injectable now (TDD)</name>
  <files>Sources/Calendar/GoogleCalendarService.swift, Tests/GoogleCalendarServiceTests.swift</files>
  <behavior>
    Rewrite the selection in `checkActiveEvents` to:
    - Add an injectable now: `func checkActiveEvents(now: Date = Date())` (default preserves the timer call `self.checkActiveEvents()` and existing no-arg test calls).
    - Read lead time from UserDefaults: `let lead = UserDefaults.standard.object(forKey: "meetingPromptLeadTimeSeconds") as? Double ?? 120` (object-check so the default is not masked by a 0).
    - Select: `meetingEvents.first { $0.shouldPrompt(leadTime: lead, now: now) && !dismissedEventIDs.contains($0.id) }`.
    - PRESERVE unchanged: the `guard let onSignal else { return }` startup-window guard (do not consume lastActiveEventID when nil), the `event.id != lastActiveEventID` once-per-event dedup, and the else-branch deactivating signal when lastActiveEventID != nil.

    Tests (add to GoogleCalendarServiceTests.swift; use injectCachedEvents/setOnSignal/SignalBox; pass explicit `now` for determinism; set and tear down the UserDefaults key):
    - event starting in 90s with default 120s lead -> fires exactly ONE signal, calendarEventID matches, isActive == true
    - event starting in 200s with default 120s lead -> fires NO signal yet (not within window)
    - changing persisted lead: same 200s event with lead 300 set in UserDefaults -> now fires
    - dedup: two consecutive checkActiveEvents(now:) for the same in-window event -> exactly one signal
    - existing tests (nil-onSignal defer, dismissed event) still pass unchanged
    In setUp/tearDown (or per-test defer) remove `meetingPromptLeadTimeSeconds` so tests don't pollute each other or the user's defaults: `UserDefaults.standard.removeObject(forKey: "meetingPromptLeadTimeSeconds")`.
  </action>
  <action>
    Write failing tests FIRST (RED), confirm with `make test`, then implement the selection change (GREEN). Match the existing DEBUG-seam / SignalBox test style already in GoogleCalendarServiceTests.swift. Do not touch the poll timer, fetch logic, or stop() semantics.
  </action>
  <verify>
    <automated>make test 2>&1 | tail -20</automated>
  </verify>
  <done>checkActiveEvents selects by shouldPrompt + UserDefaults lead time with injectable now; new + existing service tests pass; dedup and onSignal-nil guard preserved. One atomic commit: `feat(cal-03): fire meeting prompt within configurable lead time`. Commit message MUST NOT contain a Co-Authored-By line.</done>
</task>

<task type="auto">
  <name>Task 3: Settings lead-time picker + README update</name>
  <files>Sources/UI/Settings/SettingsView.swift, README.md</files>
  <action>
    SettingsView.swift — add a lead-time Picker following the existing @State/onChange section pattern (mirror `gracePeriod` in generalSection and the Binding style in updatesSection):
    - Add `@State private var promptLeadTime: Double = 120`.
    - Place a Picker inside `generalSection` (below Grace period) OR a small new "Meetings" Section — pick whichever reads cleanly; generalSection is acceptable.
    - Picker("Prompt lead time", selection: $promptLeadTime) with tags: Text("1 minute").tag(60.0), Text("2 minutes").tag(120.0), Text("5 minutes").tag(300.0). Add a caption: "How early before a meeting starts Caddie asks if you want to record."
    - Load in `.onAppear`: `promptLeadTime = UserDefaults.standard.object(forKey: "meetingPromptLeadTimeSeconds") as? Double ?? 120`.
    - Persist via `.onChange(of: promptLeadTime) { _, newValue in UserDefaults.standard.set(newValue, forKey: "meetingPromptLeadTimeSeconds") }`.
    Use the SAME literal key string as Task 2 (`meetingPromptLeadTimeSeconds`).

    README.md — update the calendar/notification description so it states the prompt arrives shortly BEFORE the meeting starts with a configurable lead time:
    - Line ~38 "Notify" row and/or line ~52/54 narrative: note calendar meeting prompts fire a configurable lead time (default 2 min) before start.
    - Move/adjust the Roadmap line ~178 "Pre-meeting notification" — it is now shipped, so reflect it as delivered rather than planned (do not leave it under a future/planned heading claiming it's unbuilt).
    Keep edits tight; no unrelated README churn.
  </action>
  <verify>
    <automated>make test 2>&1 | tail -20 && grep -n "meetingPromptLeadTimeSeconds" Sources/UI/Settings/SettingsView.swift && grep -in "lead time\|before" README.md | head</automated>
  </verify>
  <done>Settings shows a 1/2/5-min picker that loads from and writes to `meetingPromptLeadTimeSeconds`; build+tests green; README describes the pre-meeting configurable prompt and no longer lists it as unbuilt. One atomic commit: `feat(cal-03): add prompt lead-time setting and update README`. Commit message MUST NOT contain a Co-Authored-By line.</done>
</task>

</tasks>

<verification>
- `make test` green after each task (tests-first, RED before GREEN for Tasks 1 & 2).
- Model: shouldPrompt is a strict superset of old isNow (an isNow event has secondsUntilStart <= 0 <= lead and is not ended -> shouldPrompt true).
- Service: an event starting in 90s fires with default 120 lead; 200s does not until lead raised to 300; exactly one signal per event; onSignal-nil defer and dismissed-event suppression unchanged.
- Settings key string matches the service read key exactly.
- No second notification introduced; no auto-start behavior added; stop() deactivating signal untouched.
</verification>

<success_criteria>
- CAL-03 satisfied: the single "record this meeting?" prompt fires a configurable lead time before start (default 2 min), user-adjustable in Settings, persisted across launches.
- All existing tests still pass; new tests cover model helpers and lead-time service selection.
- Three atomic commits, files staged explicitly, `make test` green before each, NONE containing a Co-Authored-By line. ROADMAP.md NOT modified.
- README reflects the shipped pre-meeting prompt.
</success_criteria>

<output>
After completion, create `.planning/quick/260701-xbi-cal-03-fire-meeting-record-prompt-config/260701-xbi-SUMMARY.md` and update STATE.md Quick Tasks Completed table.
</output>
