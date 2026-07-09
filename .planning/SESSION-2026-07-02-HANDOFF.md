# Session Handoff — 2026-06-09 → 2026-07-02

Complete record of one long working session on **Caddie** (macOS menu-bar meeting recorder). Written to seed the next session's context. Repo: `github.com/YashD5291/Caddie` (**public** since 2026-06-12). Local: `/Users/yashdesai/Codebase/Fun/Caddie`.

---

## TL;DR — where things stand right now

- **Latest release: v1.2.2** (2026-07-02) — notarized DMG + EdDSA-signed appcast on GitHub Releases; public feed verified serving it.
- **v2.0 milestone archived** (`.planning/milestones/v2.0-*`, commit `ad31c2f`). No active milestone; next one not defined.
- **`main` is clean**, all branches merged, no work in flight.
- **Waiting on the user (manual checks only they can run):**
  1. Auto-update test: open installed v1.2.1 Caddie → should be offered 1.2.2 (first real end-to-end Sparkle validation).
  2. Live-transcription mic test: record with a real mic → live text streams → stop → diarized final transcript replaces it. **Never verified against real hardware** (shipped in v1.2.0 at user's request: "ship without testing").
- **Next planned step:** dogfood for a few days, then `/gsd:new-milestone` (candidates: AI summaries/action items, crash recovery, transcription retry).

---

## Timeline of everything that happened

### 1. Deep code review of the working tree (2026-06-09)
`/code-review` at max effort (7 finder agents + verifier agents) over the then-uncommitted Google-Calendar branch work. **10 findings**, 3 refuted along the way (converter `hasInput` "race" — safe; `monoURL != wavURL` — safe; `nonisolated(unsafe)` claims — actor is Sendable).

### 2. Quick task `260610-1ur` — fixed the 7 confirmed findings
Commits `0862b5a`, `42eec43`, `cfc4cad`:
1. Calendar signal permanently lost during startup (`lastActiveEventID` consumed while `onSignal` nil) → guard added.
2. `switchDevice` double-failure left WAV unfinalized (`stop()` guarded on already-false `isRecording`) → shared `finalizeRecording()`.
3. Notification Record action dropped the event title → passes `title:`.
4. `.error` state masked as idle → observable `lastRecordingError` + reducer absorbs late terminal events.
5. LoadingOverlay phrase Task leaked forever → `.task {}` auto-cancel.
6. `AVAudioPCMBuffer` allocated per RT render callback → preallocated/reused buffers.
7. Dead dismiss mechanism → wired end-to-end (eventID in `userInfo`, `dismissedEventIDs` consulted, stable notification identifiers). New `calendarEventID` threaded through `DetectionSignal → MeetingDetector → RecordingCoordinator`.

### 3. Release prep v1.1.0 — quick task `260610-nnu`
- **OAuth client secret** (`GOCSPX-…`) was hardcoded in `GoogleOAuthConfig.swift` → externalized to **gitignored** `Sources/Calendar/GoogleOAuthSecrets.swift` + committed `.template`. Fresh clones must copy the template.
- **Incident:** executor leaked the real secret into committed PLAN/SUMMARY docs → redacted, amended, reflog expired + `git gc --prune=now`; verified 0 occurrences in all reachable history **before any push**. GitHub never saw it.
- Sortformer bundle guard added (no runtime HuggingFace download possible → fully self-contained app).
- Version bump 1.0.0→1.1.0; ~25 commits organized; branch pushed; **PR #2** merged.

### 4. v1.1.0 released, then sabotaged, then restored
- Built (`scripts/build-dmg.sh`), notarized (`scripts/release.sh`, notary keychain profile **"Caddie"**), tagged, published — 680MB DMG with 690MB models bundled.
- **Incident:** pushing the tag triggered a pre-existing `.github/workflows/release.yml` that built a broken 964KB DMG on CI (no gitignored secrets, `| xcbeautify || true` masking failures, xcbeautify not even installed) and **overwrote the release asset + notes**. Fixed: workflow **disabled** (`gh workflow disable Release`), bogus assets deleted, correct DMG re-uploaded, notes restored. `ci.yml` has the same `|| true` false-green disease — **still unfixed, known debt**.
- **Discovery:** repo was **private** → release downloads and (later) the Sparkle feed 404 for everyone but the owner. After a full secret sweep (0 hits for all token patterns in history), user chose **make repo public** (2026-06-12). Everything resolves anonymously since.

### 5. v2.0 milestone audit → critical find
`/gsd:audit-milestone` + integration checker on the shipped code found **CAL-02 was dead code in v1.1.0**: `DecisionEngine.evaluate` requires ≥2 active signals, but the local monitors are intentionally never started (auto-detection was removed) → a calendar-only signal could never fire `onMeetingPrompt`; the entire notification path was unreachable. A unit test literally asserted the broken behavior. Audit doc: `.planning/milestones/v2.0-MILESTONE-AUDIT.md` (originally `gaps_found`; later updated to `passed` with resolutions).

### 6. PR #3 — CAL-02 fix + sign-in gate scoping (quick task `260610-p4w`)
- Lone `.googleCalendar` signal now fires the prompt directly (per-event dedup via `promptedEventIDs`); title rides in notification `userInfo`; `stop()` emits deactivating signal.
- **Sign-in gate scoped**: signed-out users keep full access to local recordings; compact sign-in card in the sidebar schedule area instead of a full-window gate (onboarding still requires sign-in — ONB-01 intact).
- Note: these commits initially landed on local `main` by mistake → moved to a branch, `main` reset, PR opened properly (user rule: never commit code directly to main).

### 7. Live transcription (superpowers flow: brainstorm → spec → plan → subagent-driven execution)
- **Decisions:** detail-view only; display-only (final diarized transcript unchanged); `LiveTranscriber` owned by coordinator.
- Spec: `docs/superpowers/specs/2026-06-11-live-transcription-design.md`. Plan: `docs/superpowers/plans/2026-06-11-live-transcription.md` (6 TDD tasks).
- **Architecture as built:** FluidAudio `StreamingAsrManager` (`.streaming` config) wrapped by `FluidStreamingEngine` (models bound at **init**) behind `StreamingTranscriptionEngine` protocol; `LiveTranscriber` is `@MainActor`; `AudioRecorder.onSamples` tee fires from the 100ms main-thread flush (RT path untouched; finalize clears the tee **before** the final drain — off-main trap fix); coordinator starts/stops it around recording; `AppState.liveConfirmedText/liveVolatileText`; scrolling live view in the recording card (confirmed `.primary`, volatile `.secondary`, "Listening…" empty state).
- **API drift discovered mid-build** (plan was stale): `streamAudio` is actor-isolated (feed hops via Task); update struct is `text` + `isConfirmed` (two-tier reconstructed in LiveTranscriber); `AsrModels` unconstructible in tests → engine takes models at init, protocol `start()` parameterless.
- **The test-suite hang saga:** suite runs wedged for hours (one xcodebuild ran 10h18m). Root cause via `sample` + crash report: `MockStreamingEngine.stream()` is a `nonisolated async` witness → runs on the **cooperative pool**, racing MainActor test mutations → `Array replace: subrange extends past the end` → host crashed or wedged intermittently. Fix: all mock state behind an `NSLock` (commit `161253f`). 8/8 repeat runs green after.
- **PR #4** merged → **v1.2.0 released** ("shit without testing" = user explicitly shipped without the manual mic check).

### 8. Sparkle auto-updates (quick task `260612-15a`, PR #6) → v1.2.1
- Sparkle 2.9 had been linked but fully inert (no feed URL/public key/updater controller since v1.0).
- Wired: `SPUStandardUpdaterController` on AppDelegate; "Check for Updates…" in menu bar; Updates section in Settings; `SUFeedURL = https://github.com/YashD5291/Caddie/releases/latest/download/appcast.xml`; existing Keychain **EdDSA key reused** (public key → Info.plist; private key ONLY in login Keychain — recommend backing it up via `generate_keys -x`).
- `release.sh` extended: generate → verify → upload signed `appcast.xml` per release (tools globbed from DerivedData `SourcePackages/artifacts/sparkle/Sparkle/bin/`). Pre-PR pass caught a pipefail bug in the tool-glob.
- **v1.2.1 released** — first auto-update-capable build. Auto-update works for ≥1.2.1 only; 1.0–1.2.0 users need one manual download.

### 9. CAL-03 — configurable pre-meeting prompt (quick task `260701-xbi`, PR #8) → shipped in v1.2.2
- **User decisions:** build it (not drop); MOVE the single prompt earlier (no second notification); lead time **configurable** (1/2/5 min picker, default 2 min).
- Implementation: now-injectable `hasEnded/startsWithin/shouldPrompt` helpers on `GoogleCalendarEvent` (deterministic tests; `isNow` untouched — still drives sidebar); `checkActiveEvents(now:)` reads UserDefaults via `object(forKey:)` (missing key → 120, never 0); shared `MeetingPromptSettings` enum (key `meetingPromptLeadTimeSeconds` + default) so Settings writer and service reader can't drift; test keeps a **deliberate literal key as a drift pin** (documented — do not "simplify" it).
- Superpowers PR review: **Ready to merge**; 3 nits fixed pre-merge (drift-pin comment, service-level all-day-event test with attendees, single-slot selection doc comment). Merged `71cf972`.

### 10. v2.0 milestone archived (commit `ad31c2f`)
- CLI `milestone complete` archived ROADMAP/REQUIREMENTS/audit to `.planning/milestones/v2.0-*`; **but** its MILESTONES.md entry only saw phases 11–13 → hand-rewrote the entry to capture the full scope (phases 14–17 shipped off-flow via PRs #2–#8).
- Requirements archive updated to final outcomes: **13/13 addressed** (11 satisfied, 2 satisfied-with-deviation: browser OAuth not ASWebAuth; notification prompt not auto-start; CAL-05 N/A — no sync tokens). Audit flipped to `passed` with CAL-02/CAL-03 resolutions recorded.
- PROJECT.md evolved (product shift documented: local auto-detection **removed**; recording is user-initiated via manual/calendar-button/notification). ROADMAP collapsed; root REQUIREMENTS.md deleted (archived).
- **Deliberate deviation: no git `v2.0` tag** — milestone name ≠ release version (software shipped as v1.1.0→v1.2.2); a v2.0 tag among semver release tags would imply a nonexistent 2.0 release.

### 11. v1.2.2 release (2026-07-02)
- Bump PR #9 (1.2.2, build 5) merged; DMG pre-built (681MB, models verified inside).
- **Incident:** notarization failed with HTTP **403 "required agreement missing or expired"** — Apple Developer Program License Agreement needed re-acceptance by the Account Holder at developer.apple.com. (`release.sh` misleadingly reports this as "Keychain profile 'Caddie' not found" — its check treats ANY notarytool failure as a missing profile. **Known fixable nit.**) User accepted; cleared in ~2 min.
- Notarized (Accepted), appcast regenerated for 1.2.2, tagged `v1.2.2`, published with DMG + sha256 + appcast. **Feed verified anonymously serving 1.2.2 with edSignature.**

---

## Environment facts & gotchas (verified this session)

- **Build/test:** `make test` (xcodebuild; full suite ≈3–5 min; ~270 tests green). XcodeGen project — new files need `xcodegen generate` (Makefile's `setup` handles it). SourceKit single-file diagnostics ("No such module XCTest", "Cannot find X in scope") are **indexing noise**, not build errors — trust `make test`.
- **Release pipeline:** `scripts/build-dmg.sh` (xcodegen → Release build → Developer ID sign + hardened runtime → DMG) then `scripts/release.sh` (notarize via keychain profile **"Caddie"** → staple → sha256 → generate/verify/upload appcast). Release flow: bump PR → merge → build → release.sh → tag → `gh release create` with DMG+sha256+appcast.
- **GitHub Actions:** `Release` workflow **disabled** (it clobbers releases with broken builds — do not re-enable without a full rewrite); `ci.yml` is false-green (`|| true`, xcbeautify missing, can't build without gitignored secrets) — **open debt**.
- **Secrets:** OAuth client id/secret live only in gitignored `Sources/Calendar/GoogleOAuthSecrets.swift` (template committed); secret IS extractable from the shipped binary — inherent to desktop OAuth, accepted. EdDSA private key only in login Keychain (unbacked-up — recommended `generate_keys -x`). Zero secrets in git history (swept repeatedly).
- **Test-host quirk:** the unit-test host is the full Caddie app — it launches AppState (token refresh / notification-auth log noise in test output is normal).
- **Hung suites:** if `make test` seems stuck, check `ps -axo pid,etime` for a long-running xcodebuild + `sample <pid>`; one intermittent race already fixed, but the diagnosis recipe is in this session's history.

## Working conventions the user enforces (from CLAUDE.md + observed)

- GSD workflow for changes (`/gsd:quick` for small, milestones for big); superpowers brainstorm→spec→plan→subagent-execution for features; **TDD always**; `/simplify` (or equivalent quality pass) before every PR; **never commit code directly to main** (docs/.planning commits to main are established practice); **no Co-Authored-By** lines; update README with user-facing changes; atomic commits; user answers option questions decisively — give crisp A/B/C choices with a recommendation.

## Open items for next session

1. **User manual checks (pending):** auto-update offer on v1.2.1 install; live-transcription mic test. If either fails → hotfix v1.2.3.
2. **Next milestone** via `/gsd:new-milestone` after a few days of dogfooding. Future list: AI summaries/action items, crash recovery, transcription retry w/ backoff, disk-space monitoring, structured error logging, health dashboard.
3. **Known tech debt:** `ci.yml` false-greens; `release.sh` misleading notarytool error message; attendee names decoded but not rendered/persisted; ONB-02 copy doesn't enumerate exact calendar data; EdDSA key backup.
4. Tags to date: `v1.0`, `v1.0.0`, `v1.1.0`, `v1.2.0`, `v1.2.1`, `v1.2.2`. PRs #2–#9 all merged.

## Key artifact locations

- Milestone archives: `.planning/milestones/v2.0-{ROADMAP,REQUIREMENTS,MILESTONE-AUDIT}.md` · Summary log: `.planning/MILESTONES.md`
- Quick-task records: `.planning/quick/260610-1ur…`, `260610-nnu…`, `260612-15a…`, `260701-xbi…` (+ table in `.planning/STATE.md`)
- Live-transcription spec/plan: `docs/superpowers/{specs,plans}/2026-06-11-live-transcription*`
- Transcript repair utility (one-off DB fix for pre-detokenizer-fix data): `scripts/fix-broken-transcripts.py`
- Persistent agent memory also updated: `~/.claude/projects/-Users-yashdesai-Codebase-Fun-Caddie/memory/` (release-pipeline notes incl. the Apple-agreement gotcha)
