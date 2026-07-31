---
phase: quick-260731-5nv
plan: 01
type: execute
depends_on: []
files_modified:
  - Sources/UI/MenuBar/MenuBarView.swift
  - .planning/REQUIREMENTS.md
  - .planning/STATE.md
autonomous: true
requirements: [F1, RES-04]

must_haves:
  truths:
    - "Choosing menu bar → Stop Recording stops the recording immediately; no dialog appears and the main thread is never blocked"
    - "No NSAlert / runModal code path remains anywhere in MenuBarView.swift (no dead helper left behind)"
    - "The full test suite still passes (`make test` → ** TEST SUCCEEDED **) — removing the modal breaks nothing"
    - "The deferred root-cause fix (drain pipeline survives main-thread stalls) is recorded as RES-04 in REQUIREMENTS.md and surfaces in STATE.md progress checks"
  artifacts:
    - path: "Sources/UI/MenuBar/MenuBarView.swift"
      provides: "Stop Recording button that calls appState.stopRecording() directly, no modal"
      contains: "appState.stopRecording()"
    - path: ".planning/REQUIREMENTS.md"
      provides: "RES-04 backlog line under Future Requirements → Resilience"
      contains: "RES-04"
    - path: ".planning/STATE.md"
      provides: "Blockers/Concerns entry pointing at the deferred drain hardening"
      contains: "RES-04"
  key_links:
    - from: "Sources/UI/MenuBar/MenuBarView.swift"
      to: "AppState.stopRecording()"
      via: "direct Button action (no NSAlert, no DispatchQueue.main.async)"
      pattern: "appState\\.stopRecording\\(\\)"
---

<objective>
Remove the Stop-confirmation modal from the menu bar. `MenuBarView.confirmStopRecording()` calls `NSAlert.runModal()`, which blocks the main thread for as long as the dialog sits open. The audio drain `DispatchSourceTimer` runs on the main queue, so while the dialog waits the ~2 s SPSC ring buffer silently overwrites and discards samples.

Purpose: This directly violates the project core value ("no lost recordings"). It is proven, not theoretical — Phase 19's manual gate (19-VALIDATION.md, Finding F1) recorded meeting 30 running 304 s wall-clock while its `.m4a` retained only 63.2 s of audio; the video stream (own queue, unaffected) captured the full 304 s. Every second the confirm dialog waits for a distracted human is a second of meeting audio destroyed.

Output: A menu bar Stop button that stops immediately, a RES-04 backlog line for the real root-cause fix (get the drain off the main queue), and a STATE.md concern so the deferred work stays visible.

Locked decisions — do NOT revisit:
- The modal is REMOVED, not replaced with a non-blocking sheet/notification. Stopping is non-destructive (the meeting is saved and transcribed), so the guard is not worth the data-loss hazard.
- The call target stays `appState.stopRecording()` — same semantics as today, only the dialog goes away. Do NOT switch it to `stopManualRecording()`.
- The main-queue drain timer is NOT reworked in this task. That is deferred as RES-04.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md
@Sources/UI/MenuBar/MenuBarView.swift
@.planning/phases/19-recording-lifecycle-integration/19-VALIDATION.md
</context>

<interfaces>
<!-- Everything the executor needs; no codebase exploration required. -->

Current call site — `Sources/UI/MenuBar/MenuBarView.swift`, `.recording` branch of `statusSection` (~line 51):

    Button {
        confirmStopRecording()
    } label: {
        Label("Stop Recording", systemImage: "stop.circle.fill")
    }

Helper to delete — same file, `// MARK: - Helpers` (lines 106–120): builds an `NSAlert` inside a `DispatchQueue.main.async`, calls `NSApp.activate(ignoringOtherApps:)`, then `alert.runModal()` and only calls `appState.stopRecording()` on `.alertFirstButtonReturn`.

Target API — `Sources/App/AppState.swift:361`:

    func stopRecording() {
        Task { await coordinator?.stopRecording() }
    }

It is already non-blocking (spawns a Task) and is safe to call straight from a SwiftUI Button action, which already runs on the main actor. No `DispatchQueue.main.async` wrapper is needed. `NSApp.activate` existed only to front the alert and must go with it.

Other `runModal()` uses in the codebase are OUT OF SCOPE and must not be touched: `Sources/App/AppState.swift:352` (`showPermissionAlert`) and `Sources/UI/MainWindow/ExportSheet.swift:94` (`NSSavePanel`). Neither runs during an active audio drain.

Testability — honest assessment: `confirmStopRecording()` is a `private` helper on a SwiftUI `View`, and the removal replaces a UI interaction with a direct call. There is no unit seam: no ViewInspector-style dependency in the project, no existing MenuBarView test, and asserting "no dialog appeared" would require a UI-automation harness this project does not have. Do NOT fabricate a test for this. Verification is: full suite stays green (no regression) + source-level grep gates + the human check that the menu item stops recording without a dialog. This is the same shape as the 19-04-T2 gate (build + grep), which is precedent in this repo.
</context>

<tasks>

<task type="auto">
  <name>Task 1: Delete confirmStopRecording() and stop directly from the menu</name>
  <files>Sources/UI/MenuBar/MenuBarView.swift</files>
  <read_first>
    - Sources/UI/MenuBar/MenuBarView.swift (whole file, 131 lines — read once, extract everything)
    - .planning/phases/19-recording-lifecycle-integration/19-VALIDATION.md § "Finding F1" (the evidence being acted on)
  </read_first>
  <action>
In `Sources/UI/MenuBar/MenuBarView.swift`:

1. In the `.recording` branch of `statusSection`, change the Stop button action from `confirmStopRecording()` to `appState.stopRecording()`. Keep the label and systemImage exactly as they are.
2. Delete the entire `confirmStopRecording()` function (lines 106–120) — the `NSAlert`, the `addButton` calls, the `NSApp.activate`, the `DispatchQueue.main.async` wrapper, and the `runModal()` branch all go. No commented-out remnant, no unused local (`title` was only used for the alert copy). Project rule: no dead code.
3. If deleting the helper leaves `// MARK: - Helpers` with only `pipelineStepLabel(_:)`, keep the MARK — it is still accurate.
4. Add a short comment directly above the Stop button explaining WHY there is no confirmation (project convention: comment workarounds and non-obvious behavior). Keep it to ~2 lines, e.g. that a modal here blocks the main thread and starves the main-queue audio drain timer, dropping ring-buffer samples (Finding F1, 19-VALIDATION.md), and that stopping is non-destructive so no guard is warranted. Do NOT write the literal words `NSAlert` or `runModal` in that comment — the acceptance gate greps for them and a comment mentioning them would be ambiguous; say "confirmation dialog" / "modal" instead.
5. Change nothing else in the file. `videoErrorRow`, `actionsSection`, and `pipelineStepLabel` are untouched.
  </action>
  <verify>
    <automated>make test</automated>
    Expect `** TEST SUCCEEDED **`. (This is a no-new-behavior change; the gate is "nothing regressed", plus the greps below.)
  </verify>
  <acceptance_criteria>
    - `grep -c 'runModal' Sources/UI/MenuBar/MenuBarView.swift` → `0`
    - `grep -c 'NSAlert' Sources/UI/MenuBar/MenuBarView.swift` → `0`
    - `grep -c 'confirmStopRecording' Sources/UI/MenuBar/MenuBarView.swift` → `0`
    - `grep -rc 'confirmStopRecording' Sources/` → no matches anywhere (helper fully gone, no orphan caller)
    - `grep -c 'appState.stopRecording()' Sources/UI/MenuBar/MenuBarView.swift` → `1`
    - `grep -c 'DispatchQueue.main.async' Sources/UI/MenuBar/MenuBarView.swift` → `0`
    - Out-of-scope modals untouched: `grep -c 'runModal' Sources/App/AppState.swift` → `1` and `grep -c 'runModal' Sources/UI/MainWindow/ExportSheet.swift` → `1`
    - `make test` prints `** TEST SUCCEEDED **`
  </acceptance_criteria>
  <done>Menu bar → Stop Recording calls `appState.stopRecording()` directly; no NSAlert/runModal/DispatchQueue.main.async remains in MenuBarView.swift; no dead helper; full suite green; the two unrelated runModal sites still present.</done>
</task>

<task type="auto">
  <name>Task 2: Record RES-04 backlog + STATE concern, confirm README needs no change</name>
  <files>.planning/REQUIREMENTS.md, .planning/STATE.md</files>
  <read_first>
    - .planning/REQUIREMENTS.md § "Future Requirements" → "### Resilience" (currently RES-01…RES-03, ~lines 41–45)
    - .planning/STATE.md § "### Blockers/Concerns" (~lines 85–91)
    - README.md lines 30–70 and 165–175 (only to confirm the confirm-dialog is not documented)
  </read_first>
  <action>
1. `.planning/REQUIREMENTS.md` — append one line under `### Resilience`, immediately after the RES-03 bullet, matching the existing bullet style:

   `- **RES-04**: Audio drain pipeline survives main-thread stalls (move the drain DispatchSourceTimer off the main queue / isolate the capture tee) — root-cause hardening for Finding F1 (19-VALIDATION.md); the blocking Stop-confirm modal was removed as the immediate mitigation`

   Do not renumber or reword RES-01…RES-03. Do not add RES-04 to the v3 checklist section — it is deferred backlog, not current-milestone scope.

2. `.planning/STATE.md` — append one bullet to `### Blockers/Concerns` so it surfaces in progress checks:

   `- RES-04 deferred: the audio drain DispatchSourceTimer runs on the main queue, so ANY main-thread stall silently discards ring-buffer samples. Finding F1 (19-VALIDATION.md) measured 304 s of meeting yielding 63.2 s of audio. The blocking Stop-confirm modal is gone (quick-260731-5nv), but the underlying fragility remains — any future main-thread modal or long synchronous work reintroduces silent audio loss.`

   Keep existing bullets unchanged. Do not touch `progress:` frontmatter or the Quick Tasks Completed table (the quick-task workflow writes that row at completion).

3. README.md — verification-only, expected to be a NO-OP. The stop flow is described only as "Start/stop recording anytime from the menu bar" (line 37), the prose paragraph (line 53), and the feature list (line 171); none of them mention a confirmation dialog, so removing it does not make any README sentence false. Confirm with the greps below and leave README.md unmodified. If — and only if — a grep surfaces confirm-dialog wording, delete that wording and note the edit in the summary.
  </action>
  <verify>
    <automated>grep -c 'RES-04' .planning/REQUIREMENTS.md .planning/STATE.md</automated>
    Expect `1` for each file.
  </verify>
  <acceptance_criteria>
    - `grep -c 'RES-04' .planning/REQUIREMENTS.md` → `1`
    - `grep -c 'RES-01' .planning/REQUIREMENTS.md` → `1` (existing backlog untouched)
    - `grep -c 'RES-04' .planning/STATE.md` → `1`
    - `grep -A2 '### Resilience' .planning/REQUIREMENTS.md` shows RES-01 still first (appended, not prepended)
    - README no-op proven: `grep -ci 'stop recording?' README.md` → `0` and `grep -ci 'are you sure' README.md` → `0` and `grep -ci 'confirmation dialog' README.md` → `0`
    - `git diff --name-only` includes `.planning/REQUIREMENTS.md` and `.planning/STATE.md`, and does NOT include `README.md`
  </acceptance_criteria>
  <done>RES-04 exists in the Resilience backlog referencing Finding F1; the same concern is in STATE.md Blockers/Concerns; README confirmed to contain no confirm-dialog wording and left unmodified.</done>
</task>

</tasks>

<verification>
1. `make test` → `** TEST SUCCEEDED **` (no regression from the removal).
2. Grep gates in both tasks' acceptance criteria all pass.
3. Human smoke check (fast, optional but recommended before merge): launch the built app, start a manual recording, let it run ~30 s, choose menu bar → Stop Recording. Expected: recording stops instantly with NO dialog, the meeting transcribes, and the resulting `.m4a` duration is within a second or two of the wall-clock recording time (the F1 symptom was a duration far shorter than elapsed).
</verification>

<success_criteria>
- Stop Recording in the menu bar stops immediately with no dialog.
- Zero `NSAlert` / `runModal` / `confirmStopRecording` references in `Sources/UI/MenuBar/MenuBarView.swift`; the two unrelated modal sites (AppState permission alert, ExportSheet save panel) are untouched.
- No dead code and no commented-out remnants of the removed helper.
- `make test` green.
- RES-04 recorded in REQUIREMENTS.md Future → Resilience and mirrored in STATE.md Blockers/Concerns, both referencing Finding F1.
- README unchanged (verified, not assumed).
</success_criteria>

<output>
Create `.planning/quick/260731-5nv-f1-lost-audio-fix-remove-blocking-stop-c/260731-5nv-SUMMARY.md` when done.
</output>
