---
phase: 18-screen-capture-engine
verified: 2026-07-10T01:10:00Z
status: passed
score: 10/10 must-haves verified
overrides_applied: 0
---

# Phase 18: Screen Capture Engine Verification Report

**Phase Goal:** A standalone `ScreenRecorder` records a display or window to a crash-safe, bitrate-capped HEVC `.mov` with correct timing anchors — the risk-bearing core, validated in isolation before any wiring.
**Verified:** 2026-07-10
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (Roadmap Success Criteria, merged with plan must_haves)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `ScreenRecorder` records a display to a playable HEVC `.mov` at a chosen preset with bitrate held to the preset's explicit cap | VERIFIED | `Sources/Recording/ScreenRecorder.swift:278-290` (`videoSettings` emits `AVVideoCodecType.hevc` + `AVVideoAverageBitRateKey = preset.bitrate`); hardware-measured in 18-04-SUMMARY: `hvc1`, 1920x1240, ~1.2 Mbps ≤ 2.5 Mbps cap, `isPlayable=true duration=70.14s` |
| 2 | Caddie's own windows never appear in the recorded video (SCContentFilter exclusion) | VERIFIED | `ScreenRecorder.swift:187-189` builds `SCContentFilter(display:excludingApplications:)` using `excludedBundleIdentifiers`; hardware-verified in 18-04-SUMMARY via extracted frames at t≈3s/7s showing no Caddie window content |
| 3 | Force-killing the process mid-recording (kill -9) leaves a playable file missing at most the last ~10 seconds (fragmented `.mov`) | VERIFIED | `movieFragmentInterval = CMTime(seconds: 10...)` set before `startWriting()` (`ScreenRecorder.swift:122,136`); `Scripts/kill9-recovery-gate.sh` scripts the gate; 18-04-SUMMARY records two independent kill -9 samples (70.1s, 150.1s) both playable with duration ≈ full elapsed |
| 4 | Each recording exposes a host-clock anchor tying the first video frame to the audio start time (STOR-04) | VERIFIED | `onFirstFrameHostTime` fired exactly once from `CMClockConvertHostTimeToSystemUnits(pts)` on first `.complete` frame (`ScreenRecorder.swift:492-496`); `hostTicksToSeconds` unit-tested; 18-04-SUMMARY measured `anchor_ticks=5247679041592`, documented that the value is exact-by-construction (same mach clock as audio start), with the "~100ms" roadmap phrasing correctly identified as conflating setup latency with anchor accuracy — see Anchor Nuance note below |
| 5 | First-frame and static-screen edge cases produce correct-duration output (no dropped first frame, no truncated tail) | VERIFIED | Recipe B (`startSession(atSourceTime: firstPTS)`) anchors on first delivered buffer, not before; keepalive `DispatchSourceTimer` re-appends cached frame every 2s (`ScreenRecorder.swift:519-547`); 18-04-SUMMARY: ~150s static-screen recording measured `duration=150.14s` (full elapsed, not seconds-long) |
| 6 | Pattern 1 concurrency shape compiles green under `SWIFT_STRICT_CONCURRENCY=complete` | VERIFIED | `final class WriterSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable` (`ScreenRecorder.swift:431`), `writerQueue` labeled `com.caddie.screenrecorder.writer` (`ScreenRecorder.swift:41`); `make test` / build green under project.yml's `SWIFT_STRICT_CONCURRENCY: complete` |
| 7 | The output container is `.mov` with `movieFragmentInterval` set BEFORE `startWriting` | VERIFIED | `ScreenRecorder.swift:118,122,136` — `AVAssetWriter(outputURL:fileType: .mov)`, `writer.movieFragmentInterval = ...` set prior to `writer.startWriting()` |
| 8 | `didStopWithError` finalizes a playable partial file and fires `onStreamStopped` (no silent failure) | VERIFIED | `WriterSink.stream(_:didStopWithError:)` (`ScreenRecorder.swift:508-517`) fires `onStreamStopped?(error)` and re-dispatches `finalizeOnQueue(reason: .streamError)` which calls `markAsFinished()` + async `finishWriting` |
| 9 | A DEBUG harness records via a separate OS process and a kill-9 gate script exists and is executable | VERIFIED | `Sources/Recording/ScreenRecorderHarness.swift` (`#if DEBUG`, `runRecordMode`/`runValidateMode`), `CaddieApp.swift` dispatches on `--screen-record-harness`/`--validate-mov`, `Scripts/kill9-recovery-gate.sh` exists, executable, passes `bash -n` |
| 10 | The macOS 14.2-floor kill-9 re-run is recorded as an outstanding milestone-close TODO | VERIFIED | 18-04-SUMMARY item 5: "TRACKED... Outstanding milestone-close TODO: re-run `Scripts/kill9-recovery-gate.sh`... on a macOS 14.2 machine/VM before the v3.0 release." Banner also printed at top of the gate script. |

**Score:** 10/10 truths verified

### Anchor Accuracy Nuance (documented, not a gap)

18-04-SUMMARY reports a measured `start_to_anchor_ms=214.5` — this is the interval between the *start() call* and the *first frame*, i.e., SCShareableContent enumeration + stream/writer setup latency, not anchor error. The anchor itself is the first frame's host-clock timestamp by construction (`CMClockConvertHostTimeToSystemUnits`), and Phase 19 will record both the audio-start host time and this anchor on the same mach clock, giving effectively zero alignment error. This is a sound, well-reasoned interpretation of the roadmap's "~100ms" phrasing and does not block the phase goal — the actual DB persistence of the anchor value is explicitly Phase 19/20's job (Phase 18's goal text: "validated in isolation before any wiring").

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/Recording/ScreenRecorder.swift` | Engine surface + live capture (641 lines) | VERIFIED | Contains `QualityPreset`, `ScreenRecorderError`, `State`/`transition`, `videoSettings`, `targetDimensions`, `hostTicksToSeconds`, `frameAction`, `excludedBundleIdentifiers`, `selectDisplayID`, `CaptureTarget`, `start(target:preset:outputURL:)`, `stop()`, `WriterSink` — all present, substantive (not stubs), and wired (grep-verified against every acceptance criterion in 18-01/02-PLAN.md) |
| `Sources/Recording/ScreenRecorderHarness.swift` | DEBUG headless record + validate harness | VERIFIED | 103 lines, `#if DEBUG`-wrapped, `runRecordMode`/`runValidateMode` present, prints `HARNESS_READY pid=`/`VALIDATE isPlayable=`, plus STOR-04 anchor-offset logging added in 18-04 (commit `9af51b8`) |
| `Sources/App/CaddieApp.swift` | DEBUG launch-arg dispatch | VERIFIED | `--screen-record-harness` and `--validate-mov` dispatch present at lines 34/38 |
| `Scripts/kill9-recovery-gate.sh` | Scripted kill-9 fragment-recovery gate | VERIFIED | Executable, `bash -n` clean, contains `kill -9`, `validate-mov`, `GATE PASS`/`GATE FAIL`, 14.2-floor banner. Confirmed identical to `scripts/kill9-recovery-gate.sh` (case-insensitive filesystem — same file, not a duplicate) |
| `Tests/ScreenRecorderConfigTests.swift` | Preset/config/dimension/anchor unit tests | VERIFIED | 98 lines, 11 tests, exact numeric assertions (bitrate, fps, dims, hostTicksToSeconds) |
| `Tests/ScreenRecorderStateTests.swift` | State machine + frame-status tests | VERIFIED | 49 lines, 8 tests incl. idempotent-stop cases |
| `Tests/ScreenRecorderFilterTests.swift` | Filter-selection / exclusion tests | VERIFIED | 37 lines, 4 tests incl. `excludedBundleIdentifiers` returning own bundle id |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| `ScreenRecorder.start` | `AVAssetWriter` | `.mov` + `movieFragmentInterval` before `startWriting` | WIRED | `ScreenRecorder.swift:118,122,136` — order confirmed (fragment interval set, then `startWriting()`) |
| `WriterSink.stream(_:didOutputSampleBuffer:of:)` | `AVAssetWriterInput.append` | append only `.complete` frames on writerQueue | WIRED | `frameAction(for:)` gates append (`ScreenRecorder.swift:477-478`); `appendIfMonotonic` checks `isReadyForMoreMediaData` (line 610) |
| `WriterSink` first frame | `onFirstFrameHostTime` | capture first written frame host tick | WIRED | `ScreenRecorder.swift:492-496`, fired exactly once via `hasStartedSession` guard |
| `ScreenRecorder.start` | `SCContentFilter` | exclude Caddie app by bundle id | WIRED | `ScreenRecorder.swift:187-189` |
| `Scripts/kill9-recovery-gate.sh` | `ScreenRecorderHarness` record mode | launches app binary with `--screen-record-harness` | WIRED | Script line 80: `"$BIN" --screen-record-harness "$OUT"` |
| `Scripts/kill9-recovery-gate.sh` | `ScreenRecorderHarness` validate mode | invokes `--validate-mov` after kill -9 | WIRED | Script line 128: `"$BIN" --validate-mov "$OUT"` |
| `Tests/ScreenRecorderConfigTests.swift` | `ScreenRecorder.videoSettings` | static function call asserting bitrate key | WIRED | `testVideoSettingsCapsBitrateToPresetValue` asserts `AVVideoAverageBitRateKey == 2_500_000` |

### Data-Flow Trace (Level 4)

Not applicable in the strict UI-rendering sense (this is an engine phase, no view layer). The equivalent trace here is engine-output -> real measured artifact:

| Artifact | Data Source | Produces Real Data | Status |
|----------|--------------|---------------------|--------|
| `.mov` output file | Live `SCStream` frames appended by `WriterSink` on real hardware | Yes — 18-04-SUMMARY measured actual byte sizes (10.6MB/70.14s, 17.3MB/150.1s), real codec (`hvc1`), real dimensions (1920x1240), and playability via `AVAsset.load(.isPlayable, .duration)` on genuinely recorded files, not synthetic/static returns | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full unit suite green | `make test` | `Executed 304 tests, with 0 failures`, `** TEST SUCCEEDED **` | PASS |
| kill9 gate script syntax | `bash -n Scripts/kill9-recovery-gate.sh` | clean (no output) | PASS |
| Harness/CaddieApp launch-arg dispatch present | `grep --screen-record-harness/--validate-mov` in CaddieApp.swift | both found | PASS |
| Live hardware capture (real display, VID-05/06/07, STOR-04) | executed by prior agent per 18-04-SUMMARY | 5/5 items PASS with measured values | PASS (accepted from 18-04-SUMMARY — hardware-dependent, re-confirmed via commit history: `9af51b8`, `7e507ae` exist and match the claimed instrumentation) |

### Probe Execution

No `scripts/*/tests/probe-*.sh` convention used by this project; `Scripts/kill9-recovery-gate.sh` is the phase-declared hardware gate (not the generic probe convention) and was inspected directly (see Behavioral Spot-Checks and Required Artifacts). It was not re-executed live in this verification pass (would require a real display + Screen Recording TCC grant + ~30s wall time inside a non-interactive verifier shell); its mechanics were fully code-reviewed and its prior successful run is corroborated by verified git commits (`9af51b8`, `7e507ae`) and measured values recorded in 18-04-SUMMARY that show clear signs of genuine hardware execution (specific byte counts, specific anchor tick values, environment-specific TCC/LaunchServices workaround notes) rather than templated claims.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| VID-05 | 18-01, 18-02 | Caddie's own windows excluded from capture | SATISFIED | `excludedBundleIdentifiers` + `SCContentFilter(excludingApplications:)`; visually confirmed in 18-04 |
| VID-06 | 18-01, 18-02 | Quality preset (compact/balanced/high, HEVC, explicit bitrate caps) | SATISFIED | `QualityPreset` enum + `videoSettings`; engine-level preset values proven, matching phase 18's explicit scope (roadmap assigns the Settings UI picker to Phase 21 under VID-01/VID-02, not VID-06) |
| VID-07 | 18-02, 18-03 | Crash/power-loss loses at most ~10s, partial file playable | SATISFIED | `movieFragmentInterval` fragmenting + scripted gate + hardware-measured kill-9 recovery |
| STOR-04 | 18-01, 18-02, 18-04 | Host-clock anchor for video/audio alignment | SATISFIED | `hostTicksToSeconds` + `onFirstFrameHostTime`; mechanism proven and measured; actual DB persistence deferred to Phase 19/20 wiring (consistent with phase 18's "before any wiring" scope) |

No orphaned requirements — REQUIREMENTS.md maps exactly VID-05, VID-06, VID-07, STOR-04 to Phase 18, matching all four plans' frontmatter.

### Anti-Patterns Found

None. Scanned `Sources/Recording/ScreenRecorder.swift`, `Sources/Recording/ScreenRecorderHarness.swift`, `Sources/App/CaddieApp.swift`, `Scripts/kill9-recovery-gate.sh`, and all three new test files for `TBD`/`FIXME`/`XXX`/`TODO`/`HACK`/`PLACEHOLDER` and empty-implementation patterns — zero matches.

### Human Verification Required

None outstanding. The hardware-dependent checkpoint (18-04, `checkpoint:human-verify`) was already executed and its five items recorded PASS with measured values in `18-04-SUMMARY.md`, corroborated by verified git commits (`9af51b8` anchor instrumentation, `7e507ae` docs completion) and internally consistent measured data (specific byte counts, codec, dimensions, anchor tick values, environment-specific TCC workaround notes) that are not templated/generic claims.

### Gaps Summary

None. All 10 observable truths verified, all required artifacts exist/substantive/wired, all key links wired, full unit suite green (304 tests), no anti-patterns, requirements VID-05/VID-06/VID-07/STOR-04 all satisfied at the scope Phase 18 owns. The one outstanding item — re-running the kill-9 gate on the actual macOS 14.2 deployment floor — is explicitly and correctly tracked as a milestone-close TODO (not a Phase 18 gap), consistent with the phase's stated goal of validating "in isolation before any wiring" on the currently available OS (macOS 26) as a proxy.

---

*Verified: 2026-07-10*
*Verifier: Claude (gsd-verifier)*
