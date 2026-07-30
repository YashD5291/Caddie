---
phase: 19-recording-lifecycle-integration
plan: 05
type: execute
status: complete
completed: 2026-07-10
requirements: [VID-03, VID-04]
verified_by: Agent-driven hardware gate (AX menu automation + tccutil; user granted Screen Recording TCC once). All five checks executed with measured values — see 19-VALIDATION.md "Manual Gate Results".
---

# Plan 19-05 Summary: Hardware Verification Gate

5/5 checks PASS on real ScreenCaptureKit through the real `RecordingCoordinator` (Debug build with bundled ML models, launched via `open -n` for correct TCC attribution).

## Results (details + measured values in 19-VALIDATION.md)

1. **Real capture** — meeting recorded via the actual menu-bar flow: `.mov` beside `.m4a`, playable, duration = true meeting length (304 s), bitrate 2.49 Mbps ≤ cap, transcript completed (`done`).
2. **Anchor** — `Video anchor … offset=0.273s` logged; consistent with 18-04's setup-latency band.
3. **Meeting #2, same session** — distinct playable `.mov` (24.0 s). The per-meeting factory provably fixes the single-use engine defect.
4. **TCC-denied degrade** (run last, via `tccutil reset ScreenCapture`) — audio recorded and transcribed normally; honest menu-bar warning with Dismiss action; `Screen capture failed to start` + `Video error surfaced` in logs; no orphan `.mov`.
5. **Quit mid-recording** — playable `.mov`, 2.8 s tail loss (≤10 s fragment window).

Cleanup done: `screenRecordingEnabled` default deleted (opt-in restored), log stream stopped, app quit. **Pending user action: re-grant Screen Recording to the Debug build in System Settings** (tccutil reset revoked it for check 4).

## Deviations

- Check order 1→2→3→5→4 (plan listed 4 before 5): TCC revocation moved last so the one unavoidable human step (re-grant) happens once, after the gate. Coverage identical.
- Check 1's stop was delayed ~3.5 min by the pre-existing Stop-confirmation modal (agent initially unaware of it) — which incidentally surfaced **Finding F1**: `NSAlert.runModal()` starves the main-queue audio drain timer; 304 s meeting → 63 s of audio persisted. Pre-existing defect (not Phase 19), logged in 19-VALIDATION.md for follow-up; candidate quick fix or Phase 20 insertion.

## Next Phase Readiness

- Phase 19 wiring is hardware-proven end to end. Phase 20 (storage/retention) can rely on: `.mov` at `videoPath(for:)`, anchor pair logged (persistence is Phase 20's STOR-04 leg), deletion/disk-guard gaps documented in README.
- Milestone-close TODO unchanged: kill-9 gate re-run on a macOS 14.2 machine.
- New follow-up: F1 modal audio-starvation defect.
